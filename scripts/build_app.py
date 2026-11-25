#!/usr/bin/env python3
"""
Self-contained CommandLineTools SwiftPM build & packaging script for Piko.
Assembles build/Piko.app completely from repository sources with zero external app templates.

Usage:
    python3 scripts/build_app.py
"""
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

APP_NAME = "Piko"
EXECUTABLE_NAME = "Piko"
BUNDLE_IDENTIFIER = "br.com.damascenorafael.reminders-menubar"
MIN_MACOS_VERSION = "13.0"

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "reminders-menubar"
BUILD_WRAPPER = REPO_ROOT / "scripts" / "build-wrapper"
WRAPPER_SRC = BUILD_WRAPPER / "Sources" / EXECUTABLE_NAME
LEGACY_WRAPPER_SRC = BUILD_WRAPPER / "Sources" / "RemindersMenuBar"
KS_CHECKOUT = BUILD_WRAPPER / ".build" / "checkouts" / "KeyboardShortcuts" / "Sources" / "KeyboardShortcuts"
OUTPUT_APP = REPO_ROOT / "build" / f"{APP_NAME}.app"
PBXPROJ_PATH = REPO_ROOT / "reminders-menubar.xcodeproj" / "project.pbxproj"
ENTITLEMENTS_PATH = SRC_DIR / "reminders_menubar.entitlements"


def read_marketing_version() -> str:
    if PBXPROJ_PATH.exists():
        match = re.search(r"MARKETING_VERSION\s*=\s*([^;\s]+);", PBXPROJ_PATH.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    return "2.2.5"


def strip_previews(code: str) -> str:
    """Remove all `#Preview ... { ... }` blocks by matching balanced braces."""
    out = []
    i = 0
    n = len(code)
    while i < n:
        match = re.search(r"(?m)^[ \t]*#Preview\b", code[i:])
        if not match:
            out.append(code[i:])
            break
        start = i + match.start()
        out.append(code[i:start])
        j = i + match.end()
        while j < n and code[j] != "{":
            j += 1
        if j >= n:
            break
        depth = 0
        in_str = False
        in_line_comment = False
        in_block_comment = False
        while j < n:
            ch = code[j]
            nxt = code[j + 1] if j + 1 < n else ""
            if in_line_comment:
                if ch == "\n":
                    in_line_comment = False
            elif in_block_comment:
                if ch == "*" and nxt == "/":
                    in_block_comment = False
                    j += 1
            elif in_str:
                if ch == "\\":
                    j += 1
                elif ch == '"':
                    in_str = False
            else:
                if ch == "/" and nxt == "/":
                    in_line_comment = True
                    j += 1
                elif ch == "/" and nxt == "*":
                    in_block_comment = True
                    j += 1
                elif ch == '"':
                    in_str = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
            j += 1
        i = j
    return "".join(out)


def preprocess_sources() -> None:
    for old_path in (LEGACY_WRAPPER_SRC, WRAPPER_SRC):
        if old_path.is_symlink():
            old_path.unlink()
        elif old_path.exists():
            shutil.rmtree(old_path)

    shutil.copytree(SRC_DIR, WRAPPER_SRC)

    for swift_file in WRAPPER_SRC.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8")
        if "#Preview" in text:
            swift_file.write_text(strip_previews(text), encoding="utf-8")


def patch_keyboard_shortcuts() -> None:
    if not KS_CHECKOUT.exists():
        raise RuntimeError(f"KeyboardShortcuts checkout missing at {KS_CHECKOUT}")

    for swift_file in KS_CHECKOUT.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8")
        updated = text
        if "#Preview" in updated:
            updated = strip_previews(updated)
        if "@Entry" in updated and "keyboardShortcutsConflictPolicy" in updated:
            updated = re.sub(
                r"extension EnvironmentValues \{\s*@Entry\s*var keyboardShortcutsConflictPolicy = KeyboardShortcuts\.ConflictPolicy\.default\s*\}",
                """private struct KeyboardShortcutsConflictPolicyKey: EnvironmentKey {
\tstatic let defaultValue = KeyboardShortcuts.ConflictPolicy.default
}

extension EnvironmentValues {
\tvar keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {
\t\tget { self[KeyboardShortcutsConflictPolicyKey.self] }
\t\tset { self[KeyboardShortcutsConflictPolicyKey.self] = newValue }
\t}
}""",
                updated,
            )
        # SwiftPM CLI generates a Bundle.module accessor that looks in Bundle.main.bundleURL
        # (Piko.app/) and then falls back to the hardcoded build machine path, crashing with
        # fatalError on other machines when the bundle lives in Contents/Resources/.
        if "bundle: .module" in updated:
            bundle_helper = """private enum KeyboardShortcutsResourceBundle {
\tnonisolated static let current: Bundle = {
\t\tlet bundleName = "KeyboardShortcuts_KeyboardShortcuts.bundle"
\t\tlet candidates: [URL?] = [
\t\t\tBundle.main.resourceURL?.appendingPathComponent(bundleName),
\t\t\tBundle.main.bundleURL.appendingPathComponent(bundleName)
\t\t]
\t\tfor candidate in candidates {
\t\t\tif let candidate, let bundle = Bundle(url: candidate) {
\t\t\t\treturn bundle
\t\t\t}
\t\t}
\t\treturn Bundle.main
\t}()
}

"""
            updated = updated.replace(
                "bundle: .module",
                "bundle: KeyboardShortcutsResourceBundle.current",
            )
            if "enum KeyboardShortcutsResourceBundle" not in updated:
                updated = re.sub(
                    r"(?m)^extension String \{",
                    bundle_helper + "extension String {",
                    updated,
                    count=1,
                )
        if updated != text:
            os.chmod(swift_file, 0o644)
            swift_file.write_text(updated, encoding="utf-8")

    # Assert patches took effect cleanly.
    for swift_file in KS_CHECKOUT.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8")
        if re.search(r"\bBundle\.module\b|bundle:\s*\.module\b", text):
            raise RuntimeError(f"Unpatched Bundle.module reference remains in {swift_file}")
        if "@Entry" in text:
            raise RuntimeError(f"Unpatched @Entry macro remains in {swift_file}")


def escape_strings_value(val: str) -> str:
    return (
        val.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def compile_xcstrings_to_lprojs(
    xcstrings_path: Path,
    resources_dir: Path,
    table_name: str,
    overrides: dict[str, str] | None = None,
) -> None:
    if not xcstrings_path.exists():
        return
    data = json.loads(xcstrings_path.read_text(encoding="utf-8"))
    strings = data.get("strings", {})

    per_lang_strings: dict[str, dict[str, str]] = {}
    per_lang_plurals: dict[str, dict[str, dict]] = {}

    for key, entry in strings.items():
        locs = entry.get("localizations", {})
        for lang, loc_data in locs.items():
            unit = loc_data.get("stringUnit")
            if unit and "value" in unit:
                val = overrides.get(key, unit["value"]) if overrides else unit["value"]
                per_lang_strings.setdefault(lang, {})[key] = val

            variations = loc_data.get("variations", {})
            plural = variations.get("plural")
            if isinstance(plural, dict) and plural:
                plural_entry: dict[str, object] = {
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                }
                for form, form_data in plural.items():
                    form_unit = form_data.get("stringUnit")
                    if form_unit and "value" in form_unit:
                        # Convert %lld -> %#@value@ friendly plural string
                        plural_entry[form] = form_unit["value"]
                if len(plural_entry) > 2:
                    per_lang_plurals.setdefault(lang, {})[key] = {
                        "NSStringLocalizedFormatKey": "%#@value@",
                        "value": plural_entry,
                    }

    all_langs = set(per_lang_strings.keys()) | set(per_lang_plurals.keys())
    for lang in sorted(all_langs):
        lproj = resources_dir / f"{lang}.lproj"
        lproj.mkdir(parents=True, exist_ok=True)

        kv = per_lang_strings.get(lang, {})
        if kv:
            lines = [
                f'"{escape_strings_value(k)}" = "{escape_strings_value(v)}";'
                for k, v in sorted(kv.items())
            ]
            (lproj / f"{table_name}.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")

        plurals = per_lang_plurals.get(lang, {})
        if plurals:
            with (lproj / f"{table_name}.stringsdict").open("wb") as f:
                plistlib.dump(plurals, f, fmt=plistlib.FMT_XML)


def expand_plist_variables(obj: object, variables: dict[str, str]) -> object:
    if isinstance(obj, str):
        return re.sub(r"\$\(([^)]+)\)", lambda m: variables.get(m.group(1), m.group(0)), obj)
    if isinstance(obj, dict):
        return {k: expand_plist_variables(v, variables) for k, v in obj.items()}
    if isinstance(obj, list):
        return [expand_plist_variables(item, variables) for item in obj]
    return obj


def generate_info_plist(dest_path: Path, marketing_version: str) -> None:
    source_plist_path = SRC_DIR / "Info.plist"
    with source_plist_path.open("rb") as f:
        raw_plist = plistlib.load(f)

    variables = {
        "DEVELOPMENT_LANGUAGE": "en",
        "EXECUTABLE_NAME": EXECUTABLE_NAME,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_IDENTIFIER,
        "PRODUCT_BUNDLE_PACKAGE_TYPE": "APPL",
        "MARKETING_VERSION": marketing_version,
        "MACOSX_DEPLOYMENT_TARGET": MIN_MACOS_VERSION,
        "PRODUCT_NAME": APP_NAME,
    }
    expanded = expand_plist_variables(raw_plist, variables)
    assert isinstance(expanded, dict)

    expanded["CFBundleName"] = APP_NAME
    expanded["CFBundleDisplayName"] = APP_NAME
    expanded["CFBundleExecutable"] = EXECUTABLE_NAME
    expanded["CFBundleIdentifier"] = BUNDLE_IDENTIFIER
    expanded["CFBundleShortVersionString"] = marketing_version
    expanded["CFBundleVersion"] = marketing_version
    expanded["LSMinimumSystemVersion"] = MIN_MACOS_VERSION
    expanded["CFBundleIconFile"] = "AppIcon"
    expanded.pop("CFBundleIconName", None)

    with dest_path.open("wb") as f:
        plistlib.dump(expanded, f, fmt=plistlib.FMT_XML)


def sdk_requires_missing_swiftui_macros(sdk_path: Path) -> bool:
    """Detect CommandLineTools SDKs (e.g. macOS 27+) where @State requires SwiftUIMacros plugin missing outside Xcode."""
    swiftui_core_mod = (
        sdk_path
        / "System"
        / "Library"
        / "Frameworks"
        / "SwiftUICore.framework"
        / "Versions"
        / "A"
        / "Modules"
        / "SwiftUICore.swiftmodule"
    )
    if not swiftui_core_mod.exists():
        return False
    uses_state_macro = False
    for iface in swiftui_core_mod.glob("*.swiftinterface"):
        try:
            if "public macro State()" in iface.read_text(encoding="utf-8", errors="ignore"):
                uses_state_macro = True
                break
        except OSError:
            continue
    if not uses_state_macro:
        return False
    # If full Xcode is active, SwiftUIMacros plugin is bundled under Developer/usr/lib/swift/host/plugins
    dev_dir = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    if dev_dir:
        for candidate in Path(dev_dir).rglob("*SwiftUIMacros*"):
            if candidate.exists():
                return False
    return True


def resolve_compatible_sdk(env: dict[str, str]) -> str | None:
    if env.get("SDKROOT"):
        return env["SDKROOT"]
    default_sdk_str = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
    if not default_sdk_str:
        return None
    default_sdk = Path(default_sdk_str).resolve()
    if not sdk_requires_missing_swiftui_macros(default_sdk):
        return None
    sdks_dir = default_sdk.parent
    candidates: list[tuple[tuple[int, ...], Path]] = []
    for entry in sdks_dir.iterdir():
        if entry.is_symlink() or not entry.is_dir():
            continue
        m = re.fullmatch(r"MacOSX(\d+(?:\.\d+)*)\.sdk", entry.name)
        if not m:
            continue
        ver = tuple(int(p) for p in m.group(1).split("."))
        candidates.append((ver, entry))
    for _, sdk_dir in sorted(candidates, key=lambda x: x[0], reverse=True):
        if not sdk_requires_missing_swiftui_macros(sdk_dir):
            return str(sdk_dir)
    return None


def main() -> None:
    print("1/4 Preprocessing sources and resolving SwiftPM packages...")
    preprocess_sources()

    env = os.environ.copy()
    cache_dir = BUILD_WRAPPER / ".build" / "module-cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    env.setdefault("CLANG_MODULE_CACHE_PATH", str(cache_dir))

    compatible_sdk = resolve_compatible_sdk(env)
    if compatible_sdk:
        env["SDKROOT"] = compatible_sdk
        print(f"    Using compatible SDK: {compatible_sdk}")

    subprocess.run(
        ["swift", "package", "--disable-sandbox", "--package-path", str(BUILD_WRAPPER), "resolve"],
        env=env,
        check=True,
    )
    patch_keyboard_shortcuts()

    print("2/4 Building release binary with SwiftPM...")
    common_flags = [
        "--disable-sandbox",
        "--package-path",
        str(BUILD_WRAPPER),
        "-c",
        "release",
        "-Xswiftc",
        "-module-cache-path",
        "-Xswiftc",
        str(cache_dir),
        "-Xcc",
        f"-fmodules-cache-path={cache_dir}",
    ]
    if compatible_sdk:
        common_flags.extend(["--sdk", compatible_sdk])
    res = subprocess.run(["swift", "build"] + common_flags, env=env)
    if res.returncode != 0:
        sys.exit(res.returncode)

    bin_dir_res = subprocess.run(
        ["swift", "build"] + common_flags + ["--show-bin-path"],
        capture_output=True,
        text=True,
        check=True,
        env=env,
    )
    bin_dir = Path(bin_dir_res.stdout.strip())
    binary_path = bin_dir / EXECUTABLE_NAME
    if not binary_path.exists():
        print(f"ERROR: Binary not found at {binary_path}")
        sys.exit(1)

    marketing_version = read_marketing_version()
    print(f"3/4 Assembling self-contained {APP_NAME}.app v{marketing_version} at {OUTPUT_APP}...")
    OUTPUT_APP.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmpdir:
        staged = Path(tmpdir) / f"{APP_NAME}.app"
        contents_dir = staged / "Contents"
        macos_dir = contents_dir / "MacOS"
        resources_dir = contents_dir / "Resources"
        macos_dir.mkdir(parents=True, exist_ok=True)
        resources_dir.mkdir(parents=True, exist_ok=True)

        (contents_dir / "PkgInfo").write_bytes(b"APPL????")

        dest_exec = macos_dir / EXECUTABLE_NAME
        shutil.copy2(binary_path, dest_exec)
        os.chmod(dest_exec, 0o755)

        generate_info_plist(contents_dir / "Info.plist", marketing_version)

        custom_icns = SRC_DIR / "Resources" / "AppIcon.icns"
        if not custom_icns.exists():
            print(f"ERROR: AppIcon.icns not found at {custom_icns}")
            sys.exit(1)
        shutil.copy2(custom_icns, resources_dir / "AppIcon.icns")

        ks_bundle = bin_dir / "KeyboardShortcuts_KeyboardShortcuts.bundle"
        if not ks_bundle.exists():
            print(f"ERROR: KeyboardShortcuts resource bundle not found at {ks_bundle}")
            sys.exit(1)
        shutil.copytree(ks_bundle, resources_dir / "KeyboardShortcuts_KeyboardShortcuts.bundle", symlinks=True)

        compile_xcstrings_to_lprojs(
            SRC_DIR / "Resources" / "Localizable.xcstrings",
            resources_dir,
            table_name="Localizable",
        )
        compile_xcstrings_to_lprojs(
            SRC_DIR / "Resources" / "InfoPlist.xcstrings",
            resources_dir,
            table_name="InfoPlist",
            overrides={"CFBundleName": APP_NAME, "CFBundleDisplayName": APP_NAME},
        )

        if OUTPUT_APP.exists():
            shutil.rmtree(OUTPUT_APP)
        shutil.move(str(staged), str(OUTPUT_APP))

    sign_identity = os.environ.get("PIKO_SIGN_IDENTITY", "-")
    print(f"4/4 Signing app bundle (identity: {sign_identity}, Hardened Runtime)...")
    sign_cmd = [
        "codesign",
        "--force",
        "--deep",
        "--options",
        "runtime",
        "--sign",
        sign_identity,
    ]
    if ENTITLEMENTS_PATH.exists():
        sign_cmd.extend(["--entitlements", str(ENTITLEMENTS_PATH)])
    sign_cmd.append(str(OUTPUT_APP))
    subprocess.run(sign_cmd, check=True)
    print(f"DONE! Built self-contained app at: {OUTPUT_APP}")


if __name__ == "__main__":
    main()
