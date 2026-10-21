#!/usr/bin/env python3
"""Generate an unencrypted, uncompressed, self-contained Kirikiri XP3 smoke test.
APIs: zeas2/Kirikiroid2 SystemImpl.cpp:inform, SystemIntf.cpp:inputString.
No game assets, network, save writes, or third-party code are included.
"""
import pathlib, struct, zlib
SCRIPT = '''// XP3Compat generated dialog smoke test
System.inform("Step 1/5: information dialog. Click OK.", "XP3Compat Info");
System.inform("Step 2/5: warning dialog. Click OK.", "XP3Compat Warning");
var chosen = System.inform("Step 3/5: choose either button.", "XP3Compat Choice", ["First", "Second"]);
System.inform("Returned button index: " + chosen, "XP3Compat Result");
var typed = System.inputString("XP3Compat Input", "Step 4/5: type a value, or Cancel.", "initial value");
System.inform("Step 5/5: input returned: " + typed + "\\nAll synchronous dialogs returned.", "XP3Compat Complete");
System.exit();
'''
def chunk(tag, data):
    return tag + struct.pack('<Q',len(data)) + data

def build():
    data = b'\xff\xfe' + SCRIPT.encode('utf-16le')
    name = 'startup.tjs'.encode('utf-16le')
    info = struct.pack('<IQQH',0,len(data),len(data),len(name)//2) + name
    segm = struct.pack('<IQQQ',0,19,len(data),len(data))
    adlr = struct.pack('<I',zlib.adler32(data)&0xffffffff)
    index = chunk(b'File',chunk(b'info',info)+chunk(b'segm',segm)+chunk(b'adlr',adlr))
    return b'XP3\r\n \n\x1a\x8b\x67\x01' + struct.pack('<Q',19+len(data)) + data + b'\x00' + struct.pack('<Q',len(index)) + index

if __name__ == '__main__':
    path=pathlib.Path(__file__).with_name('DialogSmoke.xp3')
    path.write_bytes(build())
    print(path)
