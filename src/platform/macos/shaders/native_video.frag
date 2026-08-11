#version 440

layout(location = 0) in vec2 textureCoordinate;
layout(location = 0) out vec4 fragmentColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 rangeParameters;
    vec4 chromaSiting;
    vec4 redConversion;
    vec4 greenConversion;
    vec4 blueConversion;
};

layout(binding = 1) uniform sampler2D lumaPlane;
layout(binding = 2) uniform sampler2D chromaPlane;

void main() {
    const float y =
        (texture(lumaPlane, textureCoordinate).r - rangeParameters.x) *
        rangeParameters.y;
    const vec2 uv =
        (texture(chromaPlane, textureCoordinate + chromaSiting.xy).rg -
         rangeParameters.z) * rangeParameters.w;
    const vec3 yuv = vec3(y, uv.x, uv.y);
    const vec3 rgb = clamp(vec3(dot(redConversion.xyz, yuv),
                                dot(greenConversion.xyz, yuv),
                                dot(blueConversion.xyz, yuv)),
                           0.0, 1.0);
    fragmentColor = vec4(rgb * qt_Opacity, qt_Opacity);
}
