#!/usr/bin/env python3
"""Generate small, explicit iOS linker descriptions for this SDK-less build.

These files contain no implementation and ship in neither the dylib nor the IPA.
They describe stable Apple runtime symbols used by the compiled object. An iOS
SDK build is preferred when one is available; an on-device test is still needed.
Unknown imports fail closed instead of being silently resolved by flat lookup.
"""

import argparse
import pathlib
import subprocess


LIBRARIES = {
    "System": ("/usr/lib/libSystem.B.dylib", "1.0.0"),
    "objc": ("/usr/lib/libobjc.A.dylib", "1.0.0"),
    "Foundation": ("/System/Library/Frameworks/Foundation.framework/Foundation", "300.0.0"),
    "CoreFoundation": ("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", "150.0.0"),
    "UIKit": ("/System/Library/Frameworks/UIKit.framework/UIKit", "1.0.0"),
    "CoreGraphics": ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "64.0.0"),
}

SYSTEM_SYMBOLS = {
    "dyld_stub_binder", "__Unwind_Resume", "___stack_chk_fail", "___stack_chk_guard", "___error",
    "___assert_rtn", "___chkstk_darwin", "_malloc", "_calloc", "_realloc",
    "_free", "_memcpy", "_memmove", "_memset", "_memcmp", "_strlen", "_strcmp",
    "_strncmp", "_strstr", "_strchr", "_strdup", "_strlcpy", "_strlcat", "_strerror",
    "_snprintf", "_vsnprintf", "_printf", "_fprintf", "_fputs", "_fputc", "_puts",
    "_fopen", "_fclose", "_fwrite", "_fflush", "_getenv", "_getpid", "_abort",
    "_dlopen", "_dlsym", "_dlclose", "_dlerror", "_pthread_main_np", "_pthread_self",
    "_sleep", "_usleep", "_write", "_open", "_close", "_access", "_unlink",
    "_rename", "_mkdir", "_rmdir", "_stat", "_fstat", "_time", "_gettimeofday",
    "_isfinite", "_isnan", "_floor", "_ceil", "_round", "_fmin", "_fmax",
    "___stderrp", "___stdoutp", "___stdinp", "_arc4random", "_arc4random_uniform",
}


def library_for(symbol):
    if symbol.startswith("_objc_msgSend$"):
        raise ValueError("Selector-specialized msgSend is a linker-generated stub, not a runtime export; compile with -fno-objc-msgsend-selector-stubs: " + symbol)
    if symbol == "___CFConstantStringClassReference" or symbol.startswith(("_CF", "_kCF")):
        return "CoreFoundation"
    if symbol.startswith(("_objc_", "__objc_", "_class_", "_method_", "_object_",
                          "_sel_", "_ivar_", "_protocol_", "___objc_")):
        return "objc"
    for marker in ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_", "_OBJC_EHTYPE_$_"):
        if symbol.startswith(marker):
            name = symbol[len(marker):]
            if name.startswith("NS"):
                return "Foundation"
            if name.startswith("UI"):
                return "UIKit"
            raise ValueError("Non-system Objective-C import: " + symbol)
    if symbol == "_OBJC_EHTYPE_id":
        return "objc"
    if symbol.startswith("_NS"):
        return "Foundation"
    if symbol.startswith("_UI"):
        return "UIKit"
    if symbol.startswith(("_CG", "_kCG")):
        return "CoreGraphics"
    if symbol in SYSTEM_SYMBOLS or symbol.startswith(("_dispatch_", "__dispatch_",
                                                     "__Block_", "__NSConcrete",
                                                     "_pthread_mutex_", "_pthread_once",
                                                     "__dyld_")):
        return "System"
    raise ValueError("Unrecognized import (add an explicit owning library): " + symbol)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("object", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--nm", default="nm")
    args = parser.parse_args()
    result = subprocess.run([args.nm, "-u", str(args.object)], check=True,
                            text=True, capture_output=True)
    grouped = {name: set() for name in LIBRARIES}
    # The classic bind opcodes linker adds this after object compilation.
    grouped["System"].add("dyld_stub_binder")
    errors = []
    for line in result.stdout.splitlines():
        symbol = line.strip()
        if not symbol:
            continue
        try:
            grouped[library_for(symbol)].add(symbol)
        except ValueError as error:
            errors.append(str(error))
    if errors:
        raise SystemExit("\n".join(errors))
    args.output.mkdir(parents=True, exist_ok=True)
    for library, symbols in grouped.items():
        install_name, version = LIBRARIES[library]
        # Keep all dependencies explicit even if this particular build uses none
        # of a framework's direct symbols (objc_getClass can still access it).
        quoted = ", ".join("'" + symbol + "'" for symbol in sorted(symbols))
        content = (
            "--- !tapi-tbd\n"
            "tbd-version: 4\n"
            "targets: [ arm64-ios ]\n"
            "install-name: '" + install_name + "'\n"
            "current-version: " + version + "\n"
            "compatibility-version: " + version + "\n"
            "exports:\n"
            "  - targets: [ arm64-ios ]\n"
            "    symbols: [ " + quoted + " ]\n"
            "...\n"
        )
        (args.output / (library + ".tbd")).write_text(content, encoding="utf-8")
    print("Generated explicit iOS link stubs for " +
          str(sum(len(value) for value in grouped.values())) + " imports")


if __name__ == "__main__":
    main()
