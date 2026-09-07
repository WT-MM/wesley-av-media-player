#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char** argv) {
 if(argc!=2)return 2;
 void* lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){puts(dlerror());return 1;}
 void* (*begin)(size_t)=dlsym(lib,"av_wam_reservation_begin");
 size_t (*end)(void*)=dlsym(lib,"av_wam_reservation_end");
 if(!begin||!end)return 1;
 void* domain=begin(1024);if(!domain||end(domain))return 1;
 dlclose(lib);
 for(unsigned i=0;i<_dyld_image_count();++i)
  if(strstr(_dyld_get_image_name(i),"libavutil-wamnative")) {
   puts("DecoderReservationImagePinned");return 1;
  }
 puts("allocator domain retired; zero native images");return 0;
}
