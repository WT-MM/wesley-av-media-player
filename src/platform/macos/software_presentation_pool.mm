#include "software_presentation_pool.hpp"
#import <Foundation/Foundation.h>
#include <array>
#include <cstring>
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
namespace wam::macos {
namespace {
void interleaveChroma8(std::uint8_t* out,const std::uint8_t* u,const std::uint8_t* v,unsigned width) noexcept {
  unsigned column=0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
  for(;column+16<=width;column+=16) {
    uint8x16x2_t pair;
    pair.val[0]=vld1q_u8(u+column);
    pair.val[1]=vld1q_u8(v+column);
    vst2q_u8(out+2*column,pair);
  }
#endif
  for(;column<width;++column) { out[2*column]=u[column]; out[2*column+1]=v[column]; }
}
}
SoftwarePresentationPool::~SoftwarePresentationPool() { close(); }
bool SoftwarePresentationPool::configure(std::int32_t width,std::int32_t height,OSType format) {
  close();
  if(width<=0||height<=0) return false;
  NSDictionary* attributes=@{(id)kCVPixelBufferPixelFormatTypeKey:@(format),
    (id)kCVPixelBufferWidthKey:@(width),(id)kCVPixelBufferHeightKey:@(height),
    (id)kCVPixelBufferBytesPerRowAlignmentKey:@64,
    (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
  NSDictionary* poolAttributes=@{(id)kCVPixelBufferPoolMinimumBufferCountKey:@(kDepth)};
  NSDictionary* auxiliary=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@(kDepth)};
  attributes_=static_cast<CFDictionaryRef>(CFRetain((__bridge CFDictionaryRef)auxiliary));
  if(CVPixelBufferPoolCreate(nullptr,(__bridge CFDictionaryRef)poolAttributes,
      (__bridge CFDictionaryRef)attributes,&pool_)!=kCVReturnSuccess) { close(); return false; }
  std::array<CVPixelBufferRef,kDepth> warm{};
  bool ok=true;
  for(auto& buffer:warm) { buffer=acquire(); if(!buffer) ok=false; }
  for(auto buffer:warm) if(buffer) CVPixelBufferRelease(buffer);
  if(!ok) close();
  return ok;
}
CVPixelBufferRef SoftwarePresentationPool::acquire() noexcept {
  CVPixelBufferRef result{};
  if(!pool_||CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr,pool_,attributes_,&result)!=kCVReturnSuccess) return nullptr;
  return result;
}
void SoftwarePresentationPool::close() noexcept {
  if(pool_) CFRelease(pool_); pool_=nullptr;
  if(attributes_) CFRelease(attributes_); attributes_=nullptr;
}
bool copySoftwarePlanes(CVPixelBufferRef destination,const std::uint8_t* const planes[3],
    const int strides[3],unsigned width,unsigned height,unsigned depth,bool chroma422) noexcept {
  if(!destination || (depth!=8 && depth!=10) || CVPixelBufferGetPlaneCount(destination)!=2 ||
      CVPixelBufferGetWidth(destination)!=width || CVPixelBufferGetHeight(destination)!=height) return false;
  const unsigned bytes=depth==10?2:1, chromaWidth=(width+1)/2, chromaHeight=chroma422?height:(height+1)/2;
  for(unsigned p=0;p<3;++p) if(!planes[p] || strides[p]<int((p?chromaWidth:width)*bytes)) return false;
  if(CVPixelBufferGetBytesPerRowOfPlane(destination,0)<width*bytes ||
      CVPixelBufferGetBytesPerRowOfPlane(destination,1)<chromaWidth*2*bytes) return false;
  if(CVPixelBufferLockBaseAddress(destination,0)!=kCVReturnSuccess) return false;
  if(bytes==1) {
    auto* luma=static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(destination,0));
    auto* chroma=static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(destination,1));
    const auto lumaStride=CVPixelBufferGetBytesPerRowOfPlane(destination,0);
    const auto chromaStride=CVPixelBufferGetBytesPerRowOfPlane(destination,1);
    if(!luma||!chroma) { CVPixelBufferUnlockBaseAddress(destination,0); return false; }
    for(unsigned y=0;y<height;++y) std::memcpy(luma+y*lumaStride,planes[0]+y*strides[0],width);
    for(unsigned y=0;y<chromaHeight;++y)
      interleaveChroma8(chroma+y*chromaStride,planes[1]+y*strides[1],planes[2]+y*strides[2],chromaWidth);
    CVPixelBufferUnlockBaseAddress(destination,0);
    return true;
  }
  for(unsigned p=0;p<2;++p) {
    auto* output=static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(destination,p));
    const auto rowStride=CVPixelBufferGetBytesPerRowOfPlane(destination,p);
    const unsigned rows=p?chromaHeight:height, columns=p?chromaWidth:width;
    for(unsigned y=0;y<rows;++y) {
      auto* row=output+y*rowStride;
      for(unsigned x=0;x<columns;++x) {
        for(unsigned component=0;component<(p?2U:1U);++component) {
          const unsigned source=p?1+component:0, index=p?2*x+component:x;
          const auto* input=planes[source]+y*strides[source]+x*bytes;
          std::uint16_t value; std::memcpy(&value,input,2); value=std::uint16_t(value<<6); std::memcpy(row+index*2,&value,2);
        }
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(destination,0);
  return true;
}
}
