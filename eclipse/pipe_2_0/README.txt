This is eclipse based project forked from https://github.com/doonny/PipeCNN

Configured as eclipse project for specific target device:
DE10-Nano (http://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&CategoryNo=167&No=1046&PartNo=2)

IntelFPGA for open CL version 17.0 standard must be installed properly and must have valid license to be able to compile this source code.

To Import to eclipse project

1. Use Eclipse C/C++ NEON or later.
   http://www.eclipse.org/downloads/packages/eclipse-ide-cc-developers/neon3
2. Click File-> import -> existing project into workspace
3. Select your downloaded project, find this directory and click finished.
4. Right click on project click ->C/C++ build-> Environment and add these env variables:
     - ALTERA_OCL_SDK_ROOT set to your HLD IntelFPGA directory /cygdrive/c/intelFPGA/17.0/hld/
     - add to your PATH:
        C:\intelFPGA\17.0\hld\bin;
        C:\intelFPGA\17.0\hld\host\windows64\bin;
        C:\intelFPGA\17.0\embedded\ds-5\sw\gcc\bin;
        C:\intelFPGA\17.0\embedded\host_tools\cygwin\bin;
        C:\intelFPGA_pro\17.0\embedded\ds-5\sw\gcc\bin;
     - Compile RTL lib
     - Modify makefile if necessary... 
 5. Compile project by right clicking on this project and click build project.
