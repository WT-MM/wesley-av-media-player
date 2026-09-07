#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <chrono>
int main(int argc,char** argv) {
  if(argc!=2)return 1;const auto pid=static_cast<pid_t>(std::atoi(argv[1]));
  rusage_info_v6 first{},last{},current{};bool started=false;unsigned long long peak=0;
  double begin=0,end=0;
  for(;;){
    if(proc_pid_rusage(pid,RUSAGE_INFO_V6,reinterpret_cast<rusage_info_t*>(&current))!=0)break;
    double now=std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    if(!started){first=current;begin=now;started=true;}
    if(current.ri_proc_start_abstime!=first.ri_proc_start_abstime)return 2;
    last=current;end=now;if(current.ri_phys_footprint>peak)peak=current.ri_phys_footprint;
    usleep(100000);
  }
  if(!started||end<=begin)return 3;
  mach_timebase_info_data_t timebase{};mach_timebase_info(&timebase);
  std::printf("{\"pid\":%d,\"seconds\":%.6f,\"cpu_percent_one_core\":%.6f,\"energy_joules_process\":%.9f,\"peak_footprint_bytes\":%llu}\n",pid,end-begin,
    double((last.ri_user_time-first.ri_user_time)+(last.ri_system_time-first.ri_system_time))*timebase.numer/timebase.denom/1e9/(end-begin)*100,
    double(last.ri_energy_nj-first.ri_energy_nj)/1e9,peak);
}
