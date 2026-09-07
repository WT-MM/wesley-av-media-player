#include "runtime.hpp"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
}
#include <array>
#include <cstring>
namespace wam::media::avcodec {
const char* runtimeFailure() noexcept {
  if((avcodec_version()>>16)!=63 || (avutil_version()>>16)!=61)return "AvcodecRuntimeAbiMismatch";
  for(const char* license:{avcodec_license(),avutil_license()})
    if(std::strcmp(license,"LGPL version 2.1 or later"))return "AvcodecRuntimeLicenseMismatch";
  for(const char* config:{avcodec_configuration(),avutil_configuration()})
    if(!std::strstr(config,"--disable-gpl") || !std::strstr(config,"--disable-nonfree") ||
       !std::strstr(config,"--disable-version3") || !std::strstr(config,"--disable-autodetect") ||
       std::strstr(config,"--enable-gpl") || std::strstr(config,"--enable-nonfree") ||
       std::strstr(config,"--enable-version3"))return "AvcodecRuntimeConfigurationMismatch";
  for(const auto codec:{AV_CODEC_ID_H264,AV_CODEC_ID_MPEG4,AV_CODEC_ID_VP9,
      AV_CODEC_ID_DTS,AV_CODEC_ID_TRUEHD,AV_CODEC_ID_MLP})
    if(!avcodec_find_decoder(codec))return "AvcodecRuntimeDecoderMissing";
  return nullptr;
}
}
