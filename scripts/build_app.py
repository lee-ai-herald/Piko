#!/usr/bin/env python3
"""
Standalone CommandLineTools SwiftPM build & packaging script for Piko.
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

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "reminders-menubar"
BUILD_WRAPPER = REPO_ROOT / "scripts" / "build-wrapper"
WRAPPER_SRC = BUILD_WRAPPER / "Sources" / EXECUTABLE_NAME
LEGACY_WRAPPER_SRC = BUILD_WRAPPER / "Sources" / "RemindersMenuBar"
KS_CHECKOUT = BUILD_WRAPPER / ".build" / "checkouts" / "KeyboardShortcuts" / "Sources" / "KeyboardShortcuts"
APPLICATIONS_APP = Path(f"/Applications/{APP_NAME}.app")
OUTPUT_APP = REPO_ROOT / "build" / f"{APP_NAME}.app"
TEMPLATE_CANDIDATES = [
    APPLICATIONS_APP,
    OUTPUT_APP,
    Path("/Applications/Reminders MenuBar.app"),
    REPO_ROOT / "build" / "Reminders MenuBar.app",
]


PBXPROJ_PATH = REPO_ROOT / "reminders-menubar.xcodeproj" / "project.pbxproj"


def read_marketing_version() -> str | None:
    if not PBXPROJ_PATH.exists():
        return None
    match = re.search(r"MARKETING_VERSION\s*=\s*([^;\s]+);", PBXPROJ_PATH.read_text(encoding="utf-8"))
    return match.group(1) if match else None


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
    if LEGACY_WRAPPER_SRC.is_symlink():
        LEGACY_WRAPPER_SRC.unlink()
    elif LEGACY_WRAPPER_SRC.exists():
        shutil.rmtree(LEGACY_WRAPPER_SRC)

    if WRAPPER_SRC.is_symlink():
        WRAPPER_SRC.unlink()
    elif WRAPPER_SRC.exists():
        shutil.rmtree(WRAPPER_SRC)

    shutil.copytree(SRC_DIR, WRAPPER_SRC)

    for swift_file in WRAPPER_SRC.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8")
        if "#Preview" in text:
            swift_file.write_text(strip_previews(text), encoding="utf-8")

    # Desugar @Entry in EnvironmentValues+Extensions.swift for CommandLineTools compatibility
    env_file = WRAPPER_SRC / "Extensions" / "EnvironmentValues+Extensions.swift"
    env_file.write_text(
        """import SwiftUI

private struct AppHasPopoverOpenKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var appHasPopoverOpen: Binding<Bool> {
        get { self[AppHasPopoverOpenKey.self] }
        set { self[AppHasPopoverOpenKey.self] = newValue }
    }
}
""",
        encoding="utf-8",
    )

    patch_keyboard_shortcuts()


def patch_keyboard_shortcuts() -> None:
    if not KS_CHECKOUT.exists():
        return
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

    # Guard against any remaining Bundle.module references that could fatalError on other machines.
    for swift_file in KS_CHECKOUT.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8")
        if re.search(r"\bBundle\.module\b|bundle:\s*\.module\b", text):
            raise RuntimeError(
                f"Unpatched Bundle.module reference remains in {swift_file}"
            )


def escape_strings_value(val: str) -> str:
    return (
        val.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def compile_xcstrings_to_lprojs(xcstrings_path: Path, resources_dir: Path) -> None:
    data = json.loads(xcstrings_path.read_text(encoding="utf-8"))
    strings = data.get("strings", {})

    per_lang: dict[str, dict[str, str]] = {}
    for key, entry in strings.items():
        locs = entry.get("localizations", {})
        for lang, loc_data in locs.items():
            unit = loc_data.get("stringUnit")
            if unit and "value" in unit:
                per_lang.setdefault(lang, {})[key] = unit["value"]

    for lang, kv in per_lang.items():
        lproj = resources_dir / f"{lang}.lproj"
        lproj.mkdir(parents=True, exist_ok=True)
        strings_file = lproj / "Localizable.strings"
        lines = [
            f'"{escape_strings_value(k)}" = "{escape_strings_value(v)}";'
            for k, v in sorted(kv.items())
        ]
        strings_file.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    print("1/4 Preprocessing sources for CommandLineTools SwiftPM build...")
    preprocess_sources()

    env = os.environ.copy()
    sdk26 = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    if sdk26.exists():
        env["SDKROOT"] = str(sdk26)
    cache_dir = "/tmp/rmb-clang-module-cache"
    env.setdefault("CLANG_MODULE_CACHE_PATH", cache_dir)

    # Resolve dependencies first so KeyboardShortcuts checkout exists to be patched on fresh clones
    if not KS_CHECKOUT.exists():
        subprocess.run(
            ["swift", "package", "--disable-sandbox", "--package-path", str(BUILD_WRAPPER), "resolve"],
            env=env,
            check=True,
        )
        patch_keyboard_shortcuts()

    print("2/4 Building release binary with SwiftPM...")
    common_flags = [
        "--build-system",
        "native",
        "--disable-sandbox",
        "--package-path",
        str(BUILD_WRAPPER),
        "-c",
        "release",
        "-Xswiftc",
        "-module-cache-path",
        "-Xswiftc",
        cache_dir,
        "-Xcc",
        f"-fmodules-cache-path={cache_dir}",
    ]
    cmd = ["swift", "build"] + common_flags
    res = subprocess.run(cmd, env=env)
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

    base_app = next((candidate for candidate in TEMPLATE_CANDIDATES if candidate.exists()), None)
    if base_app is None:
        print("ERROR: No template .app bundle found in /Applications or build/.")
        sys.exit(1)

    print(f"3/4 Assembling app bundle at {OUTPUT_APP} (template: {base_app})...")
    OUTPUT_APP.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmpdir:
        staged = Path(tmpdir) / f"{APP_NAME}.app"
        shutil.copytree(base_app, staged, symlinks=True)

        sparkle_fw = staged / "Contents" / "Frameworks" / "Sparkle.framework"
        if sparkle_fw.exists():
            shutil.rmtree(sparkle_fw)

        legacy_login_items = staged / "Contents" / "Library"
        if legacy_login_items.exists():
            shutil.rmtree(legacy_login_items)

        macos_dir = staged / "Contents" / "MacOS"
        for old_exec in macos_dir.iterdir():
            if old_exec.is_file() or old_exec.is_symlink():
                old_exec.unlink()

        dest_exec = macos_dir / EXECUTABLE_NAME
        shutil.copy2(binary_path, dest_exec)
        os.chmod(dest_exec, 0o755)

        info_plist_path = staged / "Contents" / "Info.plist"
        with info_plist_path.open("rb") as f:
            info_plist = plistlib.load(f)
        info_plist["CFBundleName"] = APP_NAME
        info_plist["CFBundleDisplayName"] = APP_NAME
        info_plist["CFBundleExecutable"] = EXECUTABLE_NAME
        info_plist["CFBundleIdentifier"] = BUNDLE_IDENTIFIER
        marketing_version = read_marketing_version()
        if marketing_version:
            info_plist["CFBundleShortVersionString"] = marketing_version
            info_plist["CFBundleVersion"] = marketing_version
        info_plist["CFBundleIconFile"] = "AppIcon"
        # Remove CFBundleIconName so macOS loads our custom AppIcon.icns instead of
        # falling back to the legacy AppIcon inside Assets.car.
        info_plist.pop("CFBundleIconName", None)
        for sparkle_key in (
            "SUFeedURL",
            "SUPublicEDKey",
            "SUEnableAutomaticChecks",
            "SUEnableInstallerLauncherService",
        ):
            info_plist.pop(sparkle_key, None)
        with info_plist_path.open("wb") as f:
            plistlib.dump(info_plist, f, fmt=plistlib.FMT_XML)

        custom_icns = SRC_DIR / "Resources" / "AppIcon.icns"
        if custom_icns.exists():
            shutil.copy2(custom_icns, staged / "Contents" / "Resources" / "AppIcon.icns")

        ks_bundle = bin_dir / "KeyboardShortcuts_KeyboardShortcuts.bundle"
        if not ks_bundle.exists():
            print(f"ERROR: KeyboardShortcuts resource bundle not found at {ks_bundle}")
            sys.exit(1)
        dest_ks = staged / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle"
        if dest_ks.exists():
            shutil.rmtree(dest_ks)
        shutil.copytree(ks_bundle, dest_ks, symlinks=True)

        compile_xcstrings_to_lprojs(
            SRC_DIR / "Resources" / "Localizable.xcstrings",
            staged / "Contents" / "Resources",
        )

        # Ensure localized InfoPlist.strings do not override CFBundleName with legacy name
        for info_strings in (staged / "Contents" / "Resources").glob("*.lproj/InfoPlist.strings"):
            try:
                with info_strings.open("rb") as f:
                    loc_plist = plistlib.load(f)
                changed = False
                for key in ("CFBundleName", "CFBundleDisplayName"):
                    if key in loc_plist and loc_plist[key] != APP_NAME:
                        loc_plist[key] = APP_NAME
                        changed = True
                if changed:
                    with info_strings.open("wb") as f:
                        plistlib.dump(loc_plist, f, fmt=plistlib.FMT_XML)
            except Exception:
                pass

        code_sig = staged / "Contents" / "_CodeSignature"
        if code_sig.exists():
            shutil.rmtree(code_sig)

        if OUTPUT_APP.exists():
            shutil.rmtree(OUTPUT_APP)
        shutil.move(str(staged), str(OUTPUT_APP))

    print("4/4 Ad-hoc signing app bundle...")
    subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-", str(OUTPUT_APP)],
        check=True,
    )
    print(f"DONE! Built app at: {OUTPUT_APP}")


if __name__ == "__main__":
    main()
