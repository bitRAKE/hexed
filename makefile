# NMAKE makefile - hexed
#
# Run from a Visual Studio developer prompt with the AMD64 tools selected:
#
#     VsDevCmd.bat -arch=amd64 -host_arch=amd64
#
# so link.exe and the x64 Windows SDK import libraries are on PATH.
# One trajectory: fasmg -> MS64 NEWCOFF bigobj -> link -> PE64.

fasm2root = c:\git\fasm2
win32json = c:\git\win32json
# fasmg.exe, not fasm2.cmd: the wrapper pre-includes fasm2.inc, which already
# carries dd/align/format/x86-2, and policy.g includes those itself, following
# cases_calm. Double inclusion redefines x86.<cpu>.<feature> and fails.
fasm2     = $(fasm2root)\fasmg.exe
llvmbin   = C:\Program Files\LLVM\bin

# The projection resolves 'types/...', 'backends/...' and 'contracts/...'
# against the x64 directory, and 'generated/fasm2_calm/x64/windows.inc' against
# the repository root. proc64.inc and the NEWCOFF format includes come from the
# fasm2 include directory. Everything else is relative to the including file.
calminc = $(win32json)\generated\fasm2_calm\x64;$(win32json);$(fasm2root)\include

# restrict inference-rule matching (i.e. ignore most default rules)
.SUFFIXES :
.SUFFIXES : .asm .obj

# fasmg names its output explicitly, so the rule passes $@ as well as $<.
# -e 5 keeps the error list workable; NEWCOFF debug level is set in policy.g.
#
# SET is an NMAKE built-in, not a shell command: it consumes the whole line and
# alters NMAKE's own environment, which every later command then inherits.
.asm.obj :
	set INCLUDE=$(calminc);$(INCLUDE)
	$(fasm2) -e 5 $< $@


OBJECTS = hexed.obj view.obj paint.obj

POLICY = common\policy.g common\names.g common\data_blocks.g common\vt.g hexed.h


all : hexed.exe

# hexed.response is emitted by hexed.asm through `virtual as "response"`, so the
# linker options live beside the code that depends on them.
hexed.exe : $(OBJECTS)
	link @hexed.response $**

hexed.response : hexed.obj
$(OBJECTS) : $(POLICY)


# Optional inspection. Worth running when the frame, import or section story
# changes, not on every build.
verify : hexed.exe
	"$(llvmbin)\llvm-readobj.exe" --file-headers --sections --coff-imports hexed.exe
	"$(llvmbin)\llvm-readobj.exe" --unwind hexed.exe
	"$(llvmbin)\llvm-objdump.exe" -d hexed.exe > hexed.objdump.txt
	@echo verify: ABI-calling procedures have one sub rsp, ">=" 32 bytes, size == 8 mod 16


.SILENT :

clean :
	del /Q *.obj >NUL 2>&1
	del /Q *.response >NUL 2>&1
	del /Q *.objdump.txt >NUL 2>&1
	del /Q *.exe >NUL 2>&1
