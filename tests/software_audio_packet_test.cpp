#include "media/software_audio_packet.hpp"
#include <array>
#include <cstdio>
using namespace wam::media;
int main() {
  if(!softwareAudioTickAdmitted(8,10,40,1000000) || !softwareAudioTickAdmitted(9,10,40,1000000) ||
     softwareAudioTickAdmitted(7,10,40,1000000) || softwareAudioTickAdmitted(1,0,40,1000000))return 8;
  std::array<std::byte,32> h{};
  auto put=[&](unsigned n,unsigned value){h[n]=std::byte(value);};
  put(0,0x40);put(1,5);put(2,0);put(3,40);put(4,0x60);put(5,2);
  auto minor=inspectSoftwareAudioPacket(MediaCodec::Mlp,std::span(h).first(10),10);
  if(!minor || minor->frames!=40 || minor->inputTiming!=40 || minor->majorSync)return 1;
  if(inspectSoftwareAudioPacket(MediaCodec::Mlp,std::span(h).first(10),12))return 2;
  put(1,16);put(4,0xf8);put(5,0x72);put(6,0x6f);put(7,0xbb);put(9,0x0f);
  if(!inspectSoftwareAudioPacket(MediaCodec::Mlp,h,32))return 3;
  if(inspectSoftwareAudioPacket(MediaCodec::TrueHd,h,32))return 4;
  put(9,0x1f);if(inspectSoftwareAudioPacket(MediaCodec::Mlp,h,32))return 5;
  h={};put(0,0x7f);put(1,0xfe);put(2,0x80);put(3,1);put(4,0xfc);put(5,0x3c);put(6,0x3f);put(7,0xf0);put(8,0x34);
  auto dts=inspectSoftwareAudioPacket(MediaCodec::Dts,h,1024);
  if(!dts || dts->frames!=512 || !dts->majorSync)return 6;
  if(inspectSoftwareAudioPacket(MediaCodec::Dts,h,2048))return 7;
  h={};put(0,0x64);put(1,0x58);put(2,0x20);put(3,0x25);
  if(inspectSoftwareAudioPacket(MediaCodec::Dts,h,2048))return 9;
  std::puts("software packet geometry and unqualified DTS extension refusal passed");
}
