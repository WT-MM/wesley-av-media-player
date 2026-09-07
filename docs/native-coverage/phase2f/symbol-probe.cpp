#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <string>
static void* open(const char* p) {void* h=dlopen(p,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);if(!h){std::fprintf(stderr,"%s\n",dlerror());std::exit(1);}return h;}
static void* symbol(void* h,const char* name){void* p=dlsym(h,name);Dl_info i{};if(!p||!dladdr(p,&i))std::exit(2);std::printf("%s %p %s\n",name,p,i.dli_fname);return p;}
int main(int argc,char** argv){if(argc!=2)return 3;auto m=open("../Frameworks/WAMMpvFallback.dylib");symbol(m,"mpv_client_api_version");auto f=open("../Frameworks/libavutil.61.dylib");auto u=open((std::string(argv[1])+"/libavutil-wamnative.61.dylib").c_str());auto c=open((std::string(argv[1])+"/libavcodec-wamnative.63.dylib").c_str());symbol(c,"avcodec_version");auto fg=(int(*)())symbol(f,"av_log_get_level");auto fs=(void(*)(int))symbol(f,"av_log_set_level");auto ug=(int(*)())symbol(u,"av_log_get_level");auto us=(void(*)(int))symbol(u,"av_log_set_level");auto a=fg(),b=ug();fs(17);us(29);std::printf("isolated_log_levels foreign=%d native=%d\n",fg(),ug());bool ok=fg()==17&&ug()==29;fs(a);us(b);return ok?0:4;}
