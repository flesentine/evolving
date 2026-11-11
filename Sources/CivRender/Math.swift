import simd

/// Small matrix helpers. Metal consumes column-major matrices, which is what
/// `simd_float4x4` stores, so no transposes are needed anywhere.

func degreesToRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180
}

func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovy * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, zs * near, 0)
    ))
}

func orthographic(_ left: Float, _ right: Float,
                  _ bottom: Float, _ top: Float,
                  _ near: Float, _ far: Float) -> simd_float4x4 {
    let xs = 2 / (right - left)
    let ys = 2 / (top - bottom)
    let zs = 1 / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, 0),
        SIMD4<Float>(-(right + left) / (right - left),
                     -(top + bottom) / (top - bottom),
                     near / (near - far),
                     1)
    ))
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = simd_normalize(eye - center)
    let x = simd_normalize(simd_cross(up, z))
    let y = simd_cross(z, x)
    return simd_float4x4(columns: (
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
    ))
}

func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    return m
}

func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
}

func rotationY(_ radians: Float) -> simd_float4x4 {
    let c = cos(radians), s = sin(radians)
    return simd_float4x4(columns: (
        SIMD4<Float>(c, 0, -s, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(s, 0, c, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

func rotationZ(_ radians: Float) -> simd_float4x4 {
    let c = cos(radians), s = sin(radians)
    return simd_float4x4(columns: (
        SIMD4<Float>(c, s, 0, 0),
        SIMD4<Float>(-s, c, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

func rotationX(_ radians: Float) -> simd_float4x4 {
    let c = cos(radians), s = sin(radians)
    return simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, c, s, 0),
        SIMD4<Float>(0, -s, c, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}


