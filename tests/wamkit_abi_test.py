import pathlib,subprocess,sys
binary=pathlib.Path(sys.argv[1]);exports=pathlib.Path(sys.argv[2])
actual=set(subprocess.check_output(['nm','-gUj',str(binary)],text=True).splitlines())
expected=set(exports.read_text().splitlines())
assert actual==expected,{'extra':sorted(actual-expected),'missing':sorted(expected-actual)}
print('ABI export set equals list:',len(actual),'symbols')
