#version 330 core


uniform sampler2D terrainTex;
uniform sampler2D water1;
uniform sampler2D water2;
uniform sampler2D water3;
uniform sampler2D imperfect;

uniform sampler2DArray texArrTest;

uniform vec3 playerpos;
uniform float windWaveCounter;
uniform float waterWaveCounter;
uniform int renderPass;
uniform mat4 modelViewMatrix;
uniform float dropletIntensity = 0;
uniform float windIntensity = 0;
uniform float playerUnderwater;

in vec2 uv;
in vec3 worldNormal;
in vec3 fragWorldPos;
in vec4 worldPos;
in vec4 fragPosition;
in vec4 gnormal;
in vec2 flowVectorf;
in vec4 rgba;
flat in int applyPuddles;
flat in int flags;
flat in int waterFlags;
flat in int shinyOrSkyExposed;
ivec2 size = textureSize(terrainTex, 0);

bool shiny = renderPass != 4 && shinyOrSkyExposed > 0;
bool skyExposed = renderPass == 4 && shinyOrSkyExposed > 0;

vec3 coord1 = worldPos.xyz + playerpos;

vec2 mapping = worldNormal.y != 0 ? -fragWorldPos.xz / 2 : worldNormal.x != 0 ? -fragWorldPos.zy / 2 : -fragWorldPos.xy / 2;

layout(location = 0) out vec4 outGPosition;
layout(location = 1) out vec4 outGNormal;
layout(location = 2) out vec4 outTint;
layout(location = 3) out vec4 outLight;
layout(location = 4) out vec4 outDiffraction;

#include colormap.fsh
#include commonnoise.fsh

void CommonPrePass(inout float mul)
{
    outDiffraction.xy = vec2(0);
    mul = shiny ? 0.0 : mul;
}

vec4 mix3(vec4 v1, vec4 v2, vec4 v3, float w1, float w2, float w3){
    return v1 * w1 + v2 * w2 + v3 * w3;
}

vec4 NormalMap(sampler2D tex, vec2 uv)
{
    vec4 samp = texture(tex, uv);
    samp.xyz = (samp.xyz - 0.5) * 2.0;
    return samp;
}

vec4 WaterNormal(vec2 vec)
{
    vec2 flowVec = normalize(flowVectorf);

    if (length(flowVectorf) > 0.001) {
        vec += (flowVec * waterWaveCounter);
	}
    vec.x += windWaveCounter / 16.0;

    vec4 s1 = NormalMap(water1, vec);
    vec4 s2 = NormalMap(water2, vec);
    vec4 s3 = NormalMap(water3, vec);
    
    //https://www.wolframalpha.com/input/?i=max%280%2C+abs%28%28x+modulo+3%29+-+1.5%29+-+0.5%29
    float counter = (waterWaveCounter + windWaveCounter) / 4.0;
    float cnt1 = max(0, abs(mod(counter + 0, 3) - 1.5) - 0.5);
    float cnt2 = max(0, abs(mod(counter + 1, 3) - 1.5) - 0.5);
    float cnt3 = max(0, abs(mod(counter + 2, 3) - 1.5) - 0.5);
    vec4 intp = mix3(s1, s2, s3, cnt1, cnt2, cnt3);
    
    return intp;
}

// https://gamedev.stackexchange.com/questions/86530/is-it-possible-to-calculate-the-tbn-matrix-in-the-fragment-shader
mat3 CotangentFrame(vec3 N, vec3 p, vec2 uv) {
    vec3 dp1 = dFdx(p);
    vec3 dp2 = dFdy(p);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);

    vec3 dp2perp = cross(dp2, N);
    vec3 dp1perp = cross(N, dp1);
    vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
    return mat3(T * invmax, B * invmax, N);
}

float GenSplashAt(vec3 pos)
{
    vec2 uv = 6.0 * pos.xz;

    float totalNoise = 0;
    for (int i = 0; i < 2; ++i) {
        totalNoise += dropletnoise(uv, waterWaveCounter - (0.1*i));
    }
    return totalNoise;
}

void GenSplash(inout vec3 normalMap)
{
    const vec3 deltaPos = vec3(0.01, 0.0, 0.0);
    
    float val0 = GenSplashAt(fragWorldPos.xyz);
    float val1 = GenSplashAt(fragWorldPos.xyz + deltaPos.xyz);
    float val2 = GenSplashAt(fragWorldPos.xyz - deltaPos.xyz);
    float val3 = GenSplashAt(fragWorldPos.xyz + deltaPos.zyx);
    float val4 = GenSplashAt(fragWorldPos.xyz - deltaPos.zyx);

    float xDelta = ((val1 - val0) + (val0 - val2));
    float zDelta = ((val3 - val0) + (val0 - val4));

    normalMap += vec3(xDelta * 0.5, zDelta * 0.5, 0);
}

void OpaquePass(inout vec3 normalMap, inout float mul)
{

}

void LiquidPass(inout vec3 normalMap, inout float mul)
{
    bool isLava = (waterFlags & (1<<25)) > 0;
    float div = ((waterFlags & (1<<27)) > 0) ? 90 : 20;
    float wind = ((waterFlags & 0x2000000) == 0) ? 1 : 0;
    float clampedWind = clamp(windIntensity, 0.25, 1.0);

    vec4 water = WaterNormal(mapping);
    water.rgb /= div;
    water.rgb *= clampedWind;
    
    float foam = water.a;

    vec3 nmNoise = clamp(water.rgb, -1.0, 1.0);

    mul = foam;
    
    normalMap = isLava ? vec3(0) : nmNoise;
    
    outTint = vec4(getColorMapping(terrainTex).rgb, mul);
    outTint.rgb += (nmNoise.y * 0.5 + 0.5) + foam;

    outDiffraction.xy = normalMap.xy * 0.2;

    if (shinyOrSkyExposed > 0 && dropletIntensity > 0.0) GenSplash(normalMap);
}

void TopsoilPass(inout vec3 normalMap, inout float mul)
{
}

void CommonPostPass(float mul, vec3 worldPos, vec3 normalMap, bool skipTint)
{
    mat3 tbn = transpose(CotangentFrame(worldNormal, worldPos.xyz, uv));
    mat3 invTbn = transpose(tbn);
    
    if (shiny)
    {
        vec4 imp = NormalMap(imperfect, uv * size / 512);

        normalMap = imp.xyz / 8;
    }

    vec4 color = texture(terrainTex, uv);
    if (color.a < 0.005) discard;
    
    mul = color.a < 0.01 ? 1.0 : mul;

    vec3 worldNormalMap = tbn * normalMap;
    vec3 camNormalMap = (modelViewMatrix * vec4(worldNormalMap, 0.0)).xyz;

	outGPosition = vec4(worldPos, mul);
	outGNormal = vec4(normalize(camNormalMap + gnormal.xyz), mul);
    
    outLight = rgba;
    //outLight -= color.a;
    
    outDiffraction.xy = outDiffraction.x + outDiffraction.y > 0 ? outDiffraction.xy : normalMap.xy * (1.0 - color.a) * 0.1;
    outDiffraction.z = 1.0 - color.a;
    
    if (!skipTint) outTint = vec4(getColorMapping(terrainTex).rgb, mul);
    
    bool isLava = (waterFlags & (1<<25)) > 0;
}

void main() 
{
    vec3 normalMap = vec3(0.0);
    float mul = 1.0;
    bool skipTint = false;

    CommonPrePass(mul);

    switch (renderPass)
    {
        case 0:
            OpaquePass(normalMap, mul);
            break;
        case 1:
            break;
        case 2:
            break;
        case 3:
            break;
        case 4:
            LiquidPass(normalMap, mul);
            skipTint = true;
            break;
        case 5:
            TopsoilPass(normalMap, mul);
            break;
        case 6:
            break;                       
    }
    
    CommonPostPass(mul, fragPosition.xyz, normalMap, skipTint);
}