#include "software_presentation_pool.hpp"
#import <Foundation/Foundation.h>
#include <array>
#include <cstring>
namespace wam::macos {
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
          if(bytes==1) row[index]=*input;
          else { std::uint16_t value; std::memcpy(&value,input,2); value=std::uint16_t(value<<6); std::memcpy(row+index*2,&value,2); }
        }
      }
    }
  }
  CVPixelBufferUnlockBaseAddress(destination,0);
  return true;
}
}
