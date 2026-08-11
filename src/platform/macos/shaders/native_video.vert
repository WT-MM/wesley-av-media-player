#version 440

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 textureCoordinate;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 rangeParameters;
    vec4 chromaSiting;
    vec4 redConversion;
    vec4 greenConversion;
    vec4 blueConversion;
};

out gl_PerVertex { vec4 gl_Position; };

void main() {
    textureCoordinate = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
