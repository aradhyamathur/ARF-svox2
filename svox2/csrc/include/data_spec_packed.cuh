// Copyright 2021 Alex Yu
#pragma once
#include <torch/extension.h>
#include "data_spec.hpp"

struct PackedSparseGridSpec {
    PackedSparseGridSpec(SparseGridSpec& spec)
        : data(spec.data.packed_accessor64<float, 2, torch::RestrictPtrTraits>()),
          links(spec.links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>()),
          basis_dim(spec.basis_dim),
          _offset{spec._offset.data<float>()[0],
                  spec._offset.data<float>()[1],
                  spec._offset.data<float>()[2]},
          _scaling{spec._scaling.data<float>()[0],
                   spec._scaling.data<float>()[1],
                   spec._scaling.data<float>()[2]} {
    }

    torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data;
    torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links;
    int basis_dim;
    const float _offset[3];
    const float _scaling[3];
};

struct PackedCameraSpec {
    PackedCameraSpec(CameraSpec& cam) :
        c2w(cam.c2w.packed_accessor32<float, 2, torch::RestrictPtrTraits>()),
        fx(cam.fx), fy(cam.fy), width(cam.width), height(cam.height) {}
    const torch::PackedTensorAccessor32<float, 2, torch::RestrictPtrTraits>
        c2w;
    float fx;
    float fy;
    int width;
    int height;
};

struct PackedRaysSpec {
    const torch::PackedTensorAccessor32<float, 2, torch::RestrictPtrTraits> origins;
    const torch::PackedTensorAccessor32<float, 2, torch::RestrictPtrTraits> dirs;
    PackedRaysSpec(RaysSpec& spec) :
        origins(spec.origins.packed_accessor32<float, 2, torch::RestrictPtrTraits>()),
        dirs(spec.dirs.packed_accessor32<float, 2, torch::RestrictPtrTraits>())
    { }
};

struct SingleRaySpec {
    __device__ SingleRaySpec(const float* __restrict__ origin, const float* __restrict__ dir)
        : origin{origin[0], origin[1], origin[2]},
          dir{dir[0], dir[1], dir[2]},
          vdir(dir) {}
    float origin[3];
    float dir[3];
    const float* __restrict__ vdir;
};