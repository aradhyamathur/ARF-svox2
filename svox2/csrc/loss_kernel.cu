// Copyright 2021 Alex Yu
// Loss computation-related kernels

#include <torch/extension.h>
#include <cstdint>
#include <cstdio>
#include "cuda_util.cuh"

namespace {

const int TV_GRAD_CUDA_THREADS = 256;
const int MIN_BLOCKS_PER_SM = 4;

namespace device {

__device__ __inline__
void calculate_ray_scale(float ndc_coeffx,
                         float ndc_coeffy,
                         float z,
                         float maxx,
                         float maxy,
                         float maxz,
                         float* __restrict__ scale) {
    // Cubemap
    //
    const float radius = opt.background_msi_scale * float(grid.background_nlayers) /
                        (float(grid.background_nlayers - i - 0.5f));
    const float full_thickness = opt.background_msi_scale * float(grid.background_nlayers) /
                        (float(grid.background_nlayers - i + 0.5f)) - radius;
    scale[0] = 1.f / radius; // Approx, not ideal
    scale[1] = 1.f / radius; // Approx, not ideal
    scale[2] = 1.f / full_thickness;

    if (ndc_coeffx > 0.f) {
        // Normalized to [-1, 1] (with 0.5 padding)
        // const float x_norm = (x + 0.5) / maxx * 2 - 1;
        // const float y_norm = (y + 0.5) / maxy * 2 - 1;
        const float z_norm = (z + 0.5) / maxz * 2 - 1;

        // NDC distances
        const float disparity = (1 - z_norm) / 2.f; // in [0, 1]
        scale[0] = (ndc_coeffx * disparity) * maxx * 0.5f;
        scale[1] = (ndc_coeffy * disparity) * maxy * 0.5f;
        scale[2] = -((z_norm - 1.f + 2.f / maxz) * disparity);
    } else {
        scale[0] = maxx * 0.5f;
        scale[1] = maxy * 0.5f;
        scale[2] = maxz * 0.5f;
    }
}


#define CALCULATE_RAY_SCALE(out_name) float out_name[3]; \
    calculate_ray_scale( \
            ndc_coeffx, ndc_coeffy, \
            z, \
            links.size(0), \
            links.size(1), \
            links.size(2), \
            out_name)

__global__ void tv_kernel(
        torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        float scale,
        size_t Q,
        bool ignore_edge,
        float ndc_coeffx, float ndc_coeffy,
        // Output
        float* __restrict__ out) {
    CUDA_GET_THREAD_ID_U64(tid, Q);

    typedef cub::BlockReduce<float, 1024> BlockReduce;
    __shared__ typename BlockReduce::TempStorage temp_storage;

    const int idx = tid % (end_dim - start_dim) + start_dim;
    const int xyz = tid / (end_dim - start_dim);
    const int z = xyz % (links.size(2) - 1);
    const int xy = xyz / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    if (ignore_edge && links[x][y][z] == 0) return;

    CALCULATE_RAY_SCALE(scaling);

    const float val000 = (links[x][y][z] >= 0 ?
                          data[links[x][y][z]][idx] : 0.f);
    const float null_val = (ignore_edge ? val000 : 0.f);
    const float val100 = (links[x + 1][y][z] >= 0 ?
                          data[links[x + 1][y][z]][idx] : null_val);
    const float val010 = (links[x][y + 1][z] >= 0 ?
                          data[links[x][y + 1][z]][idx] : null_val);
    const float val001 = (links[x][y][z + 1] >= 0 ?
                          data[links[x][y][z + 1]][idx] : null_val);
    const float dx = (val100 - val000) * scaling[0];
    const float dy = (val010 - val000) * scaling[1];
    const float dz = (val001 - val000) * scaling[2];
    const float tresult = sqrtf(1e-5f + dx * dx + dy * dy + dz * dz);

    const float bresult = BlockReduce(temp_storage).Sum(tresult);
    if (threadIdx.x == 0) {
        atomicAdd(out, bresult * scale);
    }
}

__launch_bounds__(TV_GRAD_CUDA_THREADS, MIN_BLOCKS_PER_SM)
__global__ void tv_grad_kernel(
        const torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        const torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        float scale,
        size_t Q,
        bool ignore_edge,
        float ndc_coeffx, float ndc_coeffy,
        // Output
        float* __restrict__ grad_data) {
    CUDA_GET_THREAD_ID_U64(tid, Q);
    float dummy;
    const int idx = tid % (end_dim - start_dim) + start_dim;
    const int xyz = tid / (end_dim - start_dim);
    const int z = xyz % (links.size(2) - 1);
    const int xy = xyz / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    if (ignore_edge && links[x][y][z] == 0) return;

    CALCULATE_RAY_SCALE(scaling);

    const float* dptr = data.data();
    const size_t ddim = data.size(1);
    float v000 = 0.f, v100 = 0.f, v010 = 0.f, v001 = 0.f;
    float* gptr000 = &dummy,
         * gptr100 = &dummy,
         * gptr010 = &dummy,
         * gptr001 = &dummy;

    if (links[x][y][z] >= 0) {
        const size_t lnk = links[x][y][z] * ddim + idx;
        v000 = dptr[lnk];
        gptr000 = grad_data + lnk;
    }
    if (links[x + 1][y][z] >= 0) {
        const size_t lnk = links[x + 1][y][z] * ddim + idx;
        v100 = dptr[lnk];
        gptr100 = grad_data + lnk;
    } else if (ignore_edge) v100 = v000;
    if (links[x][y + 1][z] >= 0) {
        const size_t lnk = links[x][y + 1][z] * ddim + idx;
        v010 = dptr[lnk];
        gptr010 = grad_data + lnk;
    } else if (ignore_edge) v010 = v000;
    if (links[x][y][z + 1] >= 0) {
        const size_t lnk = links[x][y][z + 1] * ddim + idx;
        v001 = dptr[lnk];
        gptr001 = grad_data + lnk;
    } else if (ignore_edge) v001 = v000;

    const float dx = (v100 - v000) * scaling[0];
    const float dy = (v010 - v000) * scaling[1];
    const float dz = (v001 - v000) * scaling[2];
    const float idelta = scale * rsqrtf(1e-5f + dx * dx + dy * dy + dz * dz);
    if (dx != 0.f) atomicAdd(gptr100, dx * idelta);
    if (dy != 0.f) atomicAdd(gptr010, dy * idelta);
    if (dz != 0.f) atomicAdd(gptr001, dz * idelta);
    atomicAdd(gptr000, -(dx + dy + dz) * idelta);
}

__launch_bounds__(TV_GRAD_CUDA_THREADS, MIN_BLOCKS_PER_SM)
__global__ void tv_grad_sparse_kernel(
        const torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        const torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        const int32_t* __restrict__ rand_cells,
        int start_dim, int end_dim,
        float scale,
        size_t Q,
        bool ignore_edge,
        float ndc_coeffx, float ndc_coeffy,
        // Output
        bool* __restrict__ mask_out,
        float* __restrict__ grad_data) {
    CUDA_GET_THREAD_ID_U64(tid, Q);
    const int idx = tid % (end_dim - start_dim) + start_dim;
    const int xyz = rand_cells[tid / (end_dim - start_dim)];
    const int z = xyz % (links.size(2) - 1);
    const int xy = xyz / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    const int32_t* __restrict__ links_ptr = &links[x][y][z];

    if (ignore_edge && *links_ptr == 0) return;

    CALCULATE_RAY_SCALE(scaling);

    const int offx = links.stride(0), offy = links.stride(1);

    const float v000 = links_ptr[0] >= 0 ? data[links_ptr[0]][idx] : 0.f;
    const float null_val = (ignore_edge ? v000 : 0.f);
    const float v001 = links_ptr[1] >= 0 ? data[links_ptr[1]][idx] : null_val,
                v010 = links_ptr[offy] >= 0 ? data[links_ptr[offy]][idx] : null_val,
                v100 = links_ptr[offx] >= 0 ? data[links_ptr[offx]][idx] : null_val;

    const float dx = (v100 - v000) * scaling[0];
    const float dy = (v010 - v000) * scaling[1];
    const float dz = (v001 - v000) * scaling[2];
    const float idelta = scale * rsqrtf(1e-5f + dx * dx + dy * dy + dz * dz);
#define MAYBE_ADD_SET(gp, val) if (links_ptr[gp] >= 0 && val != 0.f) { \
    atomicAdd(&grad_data[links_ptr[gp] * data.size(1) + idx], val * idelta); \
    if (mask_out != nullptr) { \
        mask_out[links_ptr[gp]] = true; \
    } \
} \

    const float sm = -(dx + dy + dz);
    MAYBE_ADD_SET(0, sm);
    MAYBE_ADD_SET(1, dz);
    MAYBE_ADD_SET(offy, dy);
    MAYBE_ADD_SET(offx, dx);

#undef MAYBE_ADD_SET
}

// Cauchy
// #define _LOGALPHA(x)  logf(1.0 + delta * x * x + 1e-3)
// #define _D_LOGALPHA(x)  (delta * 2 * x) / (1.0 + delta * x * x + 1e-3)

// Log alpha (NV)
#define _LOGALPHA(x)  logf(1.0 - expf(- delta * x) + 1e-3)
#define _D_LOGALPHA(x) ((delta * expf(-delta * fmaxf(x, 0)) * (x > 0.f)) / \
                         (1.0 - expf(-delta * fmaxf(x, 0)) + 1e-3))

__global__ void tv_logalpha_kernel(
        torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        float scale,
        size_t Q,
        float delta,
        bool ignore_edge,
        // Output
        float* __restrict__ out) {
    CUDA_GET_THREAD_ID_U64(tid, Q);

    typedef cub::BlockReduce<float, 1024> BlockReduce;
    __shared__ typename BlockReduce::TempStorage temp_storage;

    const int idx = tid % (end_dim - start_dim) + start_dim;
    const int xyz = tid / (end_dim - start_dim);
    const int z = xyz % (links.size(2) - 1);
    const int xy = xyz / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    if (ignore_edge && links[x][y][z] == 0) return;

    const float val000 = (links[x][y][z] >= 0 ?
                          _LOGALPHA(data[links[x][y][z]][idx]) : 0.f);
    const float null_val = (ignore_edge ? val000 : 0.f);
    const float val100 = (links[x + 1][y][z] >= 0 ?
                          _LOGALPHA(data[links[x + 1][y][z]][idx]) : null_val);
    const float val010 = (links[x][y + 1][z] >= 0 ?
                          _LOGALPHA(data[links[x][y + 1][z]][idx]) : null_val);
    const float val001 = (links[x][y][z + 1] >= 0 ?
                          _LOGALPHA(data[links[x][y][z + 1]][idx]) : null_val);
    const float dx = val100 - val000;
    const float dy = val010 - val000;
    const float dz = val001 - val000;
    const float tresult = sqrtf(1e-5f + dx * dx + dy * dy + dz * dz);

    const float bresult = BlockReduce(temp_storage).Sum(tresult);
    if (threadIdx.x == 0) {
        atomicAdd(out, bresult * scale);
    }
}

__launch_bounds__(TV_GRAD_CUDA_THREADS, MIN_BLOCKS_PER_SM)
__global__ void tv_logalpha_grad_kernel(
        const torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        const torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        float scale,
        size_t Q,
        float delta,
        bool ignore_edge,
        // Output
        float* __restrict__ grad_data) {
    CUDA_GET_THREAD_ID_U64(tid, Q);
    float dummy;
    const int idx = tid % (end_dim - start_dim) + start_dim;
    const int xyz = tid / (end_dim - start_dim);
    const int z = xyz % (links.size(2) - 1);
    const int xy = xyz / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    if (ignore_edge && links[x][y][z] == 0) return;

    const float* dptr = data.data();
    const size_t ddim = data.size(1);
    float v000 = 0.f, v100 = 0.f, v010 = 0.f, v001 = 0.f;
    float* gptr000 = &dummy,
         * gptr100 = &dummy,
         * gptr010 = &dummy,
         * gptr001 = &dummy;

    if (links[x][y][z] >= 0) {
        const size_t lnk = links[x][y][z] * ddim + idx;
        v000 = dptr[lnk];
        gptr000 = grad_data + lnk;
    }
    if (links[x + 1][y][z] >= 0) {
        const size_t lnk = links[x + 1][y][z] * ddim + idx;
        v100 = dptr[lnk];
        gptr100 = grad_data + lnk;
    } else if (ignore_edge) v100 = v000;
    if (links[x][y + 1][z] >= 0) {
        const size_t lnk = links[x][y + 1][z] * ddim + idx;
        v010 = dptr[lnk];
        gptr010 = grad_data + lnk;
    } else if (ignore_edge) v010 = v000;
    if (links[x][y][z + 1] >= 0) {
        const size_t lnk = links[x][y][z + 1] * ddim + idx;
        v001 = dptr[lnk];
        gptr001 = grad_data + lnk;
    } else if (ignore_edge) v001 = v000;

    const float dx = v100 - v000;
    const float dy = v010 - v000;
    const float dz = v001 - v000;
    const float idelta = scale * rsqrtf(1e-5f + dx * dx + dy * dy + dz * dz);
    if (dx != 0.f) atomicAdd(gptr100, dx * idelta * _D_LOGALPHA(v100));
    if (dy != 0.f) atomicAdd(gptr010, dy * idelta * _D_LOGALPHA(v010));
    if (dz != 0.f) atomicAdd(gptr001, dz * idelta * _D_LOGALPHA(v001));
    atomicAdd(gptr000, -(dx + dy + dz) * idelta);
}

__launch_bounds__(TV_GRAD_CUDA_THREADS, MIN_BLOCKS_PER_SM)
__global__ void tv_logalpha_grad_sparse_kernel(
        const torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        const torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        const int32_t* __restrict__ rand_cells,
        int start_dim, int end_dim,
        float scale,
        size_t Q,
        float delta,
        bool ignore_edge,
        // Output
        bool* __restrict__ mask_out,
        float* __restrict__ grad_data) {
    CUDA_GET_THREAD_ID_U64(tid, Q);
    const int idx = tid % (end_dim - start_dim) + start_dim;
    const int xyz = rand_cells[tid / (end_dim - start_dim)];
    const int z = xyz % (links.size(2) - 1);
    const int xy = xyz / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    const int32_t* __restrict__ links_ptr = &links[x][y][z];

    if (ignore_edge && *links_ptr == 0) return;
    const int offx = links.stride(0), offy = links.stride(1);

    const float v000 = links_ptr[0] >= 0 ? data[links_ptr[0]][idx] : 0.f;
    const float null_val = (ignore_edge ? v000 : 0.f);
    const float v001 = links_ptr[1] >= 0 ? data[links_ptr[1]][idx] : null_val,
                v010 = links_ptr[offy] >= 0 ? data[links_ptr[offy]][idx] : null_val,
                v100 = links_ptr[offx] >= 0 ? data[links_ptr[offx]][idx] : null_val;

    const float dx = v100 - v000;
    const float dy = v010 - v000;
    const float dz = v001 - v000;
    const float idelta = scale * rsqrtf(1e-5f + dx * dx + dy * dy + dz * dz);
#define MAYBE_ADD_SET(gp, expr) { \
    float val = (expr);\
    if (links_ptr[gp] >= 0 && val != 0.f) { \
    atomicAdd(&grad_data[links_ptr[gp] * data.size(1) + idx], val * idelta); \
    if (mask_out != nullptr) { \
        mask_out[links_ptr[gp]] = true; \
    } \
} \
} \

    const float sm = -(dx + dy + dz);
    MAYBE_ADD_SET(0, sm * _D_LOGALPHA(v000));
    MAYBE_ADD_SET(1, dz * _D_LOGALPHA(v001));
    MAYBE_ADD_SET(offy, dy * _D_LOGALPHA(v010));
    MAYBE_ADD_SET(offx, dx * _D_LOGALPHA(v100));

#undef MAYBE_ADD_SET
}

}  // namespace device
}  // namespace


torch::Tensor tv(torch::Tensor links, torch::Tensor data,
                 int start_dim, int end_dim,
                 bool use_logalpha,
                 float logalpha_delta,
                 bool ignore_edge,
                 float ndc_coeffx,
                 float ndc_coeffy) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(links);
    TORCH_CHECK(data.is_floating_point());
    TORCH_CHECK(!links.is_floating_point());
    TORCH_CHECK(data.ndimension() == 2);
    TORCH_CHECK(links.ndimension() == 3);

    int nl = (links.size(0) - 1) * (links.size(1) - 1) * (links.size(2) - 1);
    size_t Q = nl * size_t(end_dim - start_dim);

    const int cuda_n_threads = 1024;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    torch::Tensor result = torch::zeros({}, data.options());
    if (use_logalpha) {
        // TODO this should also use scaling
        device::tv_logalpha_kernel<<<blocks, cuda_n_threads>>>(
                links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
                data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
                start_dim,
                end_dim,
                1.f / nl,
                Q,
                logalpha_delta,
                ignore_edge,
                // Output
                result.data_ptr<float>());
    } else {
        device::tv_kernel<<<blocks, cuda_n_threads>>>(
                links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
                data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
                start_dim,
                end_dim,
                1.f / nl,
                Q,
                ignore_edge,
                ndc_coeffx, ndc_coeffy,
                // Output
                result.data_ptr<float>());
    }
    CUDA_CHECK_ERRORS;
    return result;
}

void tv_grad(torch::Tensor links,
             torch::Tensor data,
             int start_dim, int end_dim,
             float scale,
             bool use_logalpha,
             float logalpha_delta,
             bool ignore_edge,
             float ndc_coeffx,
             float ndc_coeffy,
             torch::Tensor grad_data) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(links);
    CHECK_INPUT(grad_data);
    TORCH_CHECK(data.is_floating_point());
    TORCH_CHECK(grad_data.is_floating_point());
    TORCH_CHECK(!links.is_floating_point());
    TORCH_CHECK(data.ndimension() == 2);
    TORCH_CHECK(links.ndimension() == 3);
    TORCH_CHECK(grad_data.ndimension() == 2);

    int nl = (links.size(0) - 1) * (links.size(1) - 1) * (links.size(2) - 1);
    size_t Q = nl * size_t(end_dim - start_dim);

    const int cuda_n_threads = TV_GRAD_CUDA_THREADS;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    if (use_logalpha) {
        device::tv_logalpha_grad_kernel<<<blocks, cuda_n_threads>>>(
                links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
                data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
                start_dim,
                end_dim,
                scale / nl,
                Q,
                logalpha_delta,
                ignore_edge,
                // Output
                grad_data.data_ptr<float>());
    } else {
        device::tv_grad_kernel<<<blocks, cuda_n_threads>>>(
                links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
                data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
                start_dim,
                end_dim,
                scale / nl,
                Q,
                ignore_edge,
                ndc_coeffx, ndc_coeffy,
                // Output
                grad_data.data_ptr<float>());
    }
    CUDA_CHECK_ERRORS;
}

void tv_grad_sparse(torch::Tensor links,
             torch::Tensor data,
             torch::Tensor rand_cells,
             torch::Tensor mask_out,
             int start_dim, int end_dim,
             float scale,
             bool use_logalpha,
             float logalpha_delta,
             bool ignore_edge,
             float ndc_coeffx,
             float ndc_coeffy,
             torch::Tensor grad_data) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(links);
    CHECK_INPUT(grad_data);
    CHECK_INPUT(rand_cells);
    CHECK_INPUT(mask_out);
    TORCH_CHECK(data.is_floating_point());
    TORCH_CHECK(grad_data.is_floating_point());
    TORCH_CHECK(!links.is_floating_point());
    TORCH_CHECK(data.ndimension() == 2);
    TORCH_CHECK(links.ndimension() == 3);
    TORCH_CHECK(grad_data.ndimension() == 2);

    int nl = rand_cells.size(0);
    size_t Q = rand_cells.size(0) * size_t(end_dim - start_dim);

    const int cuda_n_threads = TV_GRAD_CUDA_THREADS;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    if (use_logalpha) {
        device::tv_logalpha_grad_sparse_kernel<<<blocks, cuda_n_threads>>>(
                links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
                data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
                rand_cells.data_ptr<int32_t>(),
                start_dim,
                end_dim,
                scale / nl,
                Q,
                logalpha_delta,
                ignore_edge,
                // Output
                (mask_out.dim() > 0) ? mask_out.data_ptr<bool>() : nullptr,
                grad_data.data_ptr<float>());
    } else {
        device::tv_grad_sparse_kernel<<<blocks, cuda_n_threads>>>(
                links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
                data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
                rand_cells.data_ptr<int32_t>(),
                start_dim,
                end_dim,
                scale / nl,
                Q,
                ignore_edge,
                ndc_coeffx, ndc_coeffy,
                // Output
                (mask_out.dim() > 0) ? mask_out.data_ptr<bool>() : nullptr,
                grad_data.data_ptr<float>());
    }
    CUDA_CHECK_ERRORS;
}
