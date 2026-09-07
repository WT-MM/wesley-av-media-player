import pathlib,subprocess,sys,tempfile
framework=pathlib.Path(sys.argv[1]);scratch=pathlib.Path('/private/tmp/wam-wamkit-scratch');scratch.mkdir(exist_ok=True)
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
with tempfile.TemporaryDirectory(dir=scratch,prefix='headers-') as directory:
 for language,source,flags in [('c','#include <WAMKit/WAMKit.h>\n#include <WAMKit/WAMKitObjC.h>\nint main(void){wam_time_t t={1001,30000,0};return t.timescale==0;}\n',['-std=c11']),('objective-c','#import <WAMKit/WAMKitObjC.h>\nvoid use(WAMPlayer *p){WAMPresentationView *v=p.presentationView;(void)v;}\n',['-fobjc-arc'])]:
  subprocess.run(['xcrun','clang','-fsyntax-only','-Werror','-isysroot',sdk,'-F',str(framework.parent),'-x',language,*flags,'-'],input=source,text=True,check=True)
 swift=pathlib.Path(directory)/'Import.swift';swift.write_text('import WAMKit\nlet t = wam_time_t(value: 1001, timescale: 30000, reserved: 0)\n')
 subprocess.run(['xcrun','swiftc','-typecheck','-sdk',sdk,'-F',str(framework.parent),'-module-cache-path',str(pathlib.Path(directory)/'modules'),str(swift)],check=True)
print('C11, Objective-C and Swift module imports passed without Qt or C++ search paths')
