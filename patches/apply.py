#!/usr/bin/env python3
"""Turn a fresh checkout of iebb/mithka into this build's source tree.

Everything this builder changes is applied here, against the upstream sources,
so the checkout itself stays pristine and the diff is one readable script
instead of a vendored copy. Every substitution asserts on its anchor: when
upstream moves the code this patches, the build fails loudly here instead of
shipping a half-patched app.

Usage:
    apply.py --src DIR --application-id ID --app-name NAME
             --update-owner OWNER --update-repo REPO --version-code N
"""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
OVERLAY = HERE.parent / "overlay"


class PatchError(RuntimeError):
    pass


def read(path: pathlib.Path) -> str:
    if not path.is_file():
        raise PatchError(f"missing file: {path}")
    return path.read_text(encoding="utf-8")


def write(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, what: str) -> str:
    if text.count(old) != 1:
        raise PatchError(f"anchor not found exactly once: {what}")
    return text.replace(old, new, 1)


def replace_regex(text: str, pattern: str, new: str, what: str) -> str:
    updated, count = re.subn(pattern, new, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise PatchError(f"anchor not found: {what}")
    return updated


def patch_application_id(src: pathlib.Path, application_id: str) -> None:
    """Keep the Kotlin namespace, change only the installed package name.

    The namespace decides where `R` and the Kotlin sources live, so it stays
    `ad.neko.mithka`; only `applicationId` — what the system and any Firebase
    config see — changes.
    """
    path = src / "android/app/build.gradle.kts"
    text = read(path)
    text = replace_once(
        text,
        'applicationId = "ad.neko.mithka"',
        f'applicationId = "{application_id}"',
        "android applicationId",
    )
    write(path, text)


def patch_manifest_label(src: pathlib.Path, app_name: str) -> None:
    if app_name == "Mithka":
        return
    path = src / "android/app/src/main/AndroidManifest.xml"
    text = read(path)
    if 'android:label="Mithka"' not in text:
        raise PatchError("anchor not found: manifest label")
    write(path, text.replace('android:label="Mithka"', f'android:label="{app_name}"'))


def patch_release_feed(src: pathlib.Path, owner: str, repo: str) -> None:
    path = src / "lib/update/release_feed.dart"
    text = read(path)
    text = replace_once(
        text,
        "const _owner = 'iebb';\nconst _repo = 'mithka';",
        f"const _owner = '{owner}';\nconst _repo = '{repo}';",
        "release feed owner/repo",
    )
    # This builder publishes `<upstream version>.<build sequence>`, so a rebuilt
    # or re-patched package is still newer than the install it replaces; the
    # comparison therefore has to look at the fourth component too.
    text = replace_regex(
        text,
        r"/// >0 if a>b, <0 if a<b, 0 if equal — compares the X\.Y\.Z triple\.\n"
        r"int compareReleaseVersions\(String a, String b\) \{.*?"
        r"return numbers\.sublist\(0, 3\);\n\}",
        """/// >0 if a>b, <0 if a<b, 0 if equal — compares up to four components.
int compareReleaseVersions(String a, String b) {
  final pa = _components(a);
  final pb = _components(b);
  for (var i = 0; i < pa.length; i++) {
    if (pa[i] != pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

List<int> _components(String version) {
  // Strip any "+build" / pre-release suffix, then parse up to 4 numbers.
  final core = version.split(RegExp(r'[+\\-]')).first;
  final numbers = core
      .split('.')
      .map((part) => int.tryParse(part.trim()) ?? 0)
      .toList();
  while (numbers.length < 4) {
    numbers.add(0);
  }
  return numbers.sublist(0, 4);
}""",
        "release version comparison",
    )
    write(path, text)


def patch_update_checker(src: pathlib.Path) -> None:
    path = src / "lib/update/update_checker.dart"
    text = read(path)
    text = replace_once(
        text,
        "import 'desktop_updater.dart';",
        "import 'android_apk_installer.dart';\nimport 'desktop_updater.dart';",
        "android installer import",
    )
    # Android no longer hands the URL to a browser: the package is downloaded,
    # verified and opened in the system installer without leaving the app.
    text = replace_regex(
        text,
        r"  static Future<UpdateCheckOutcome> _offerAndroidApk\(.*?\n  \}\n\n"
        r"  /// Offers the desktop package for this architecture",
        """  static Future<UpdateCheckOutcome> _offerAndroidApk(
    BuildContext context,
    ReleaseInfo release,
    String current,
  ) async {
    final abis = await _deviceAbis();
    if (abis.isEmpty) return UpdateCheckOutcome.unavailable;
    final asset = _apkFor(release, abis);
    // A newer release with no APK for this architecture is not something the
    // user can act on, so it is not reported as available.
    if (asset == null) return UpdateCheckOutcome.unavailable;
    if (!context.mounted) return UpdateCheckOutcome.updateAvailable;

    final ok = await confirmDialog(
      context,
      title: AppStrings.t(AppStringKeys.updateNewVersionFound),
      message: AppStrings.t(AppStringKeys.updateVersionPrompt, {
        'value1': current,
        'value2': release.version,
      }),
      confirmText: AppStrings.t(AppStringKeys.updateAction),
      cancelText: AppStrings.t(AppStringKeys.updateLater),
    );
    if (!ok || !context.mounted) return UpdateCheckOutcome.updateAvailable;
    await runAndroidApkUpdate(context, asset: asset, version: release.version);
    return UpdateCheckOutcome.updateAvailable;
  }

  /// Offers the desktop package for this architecture""",
        "android update offer",
    )
    text = replace_regex(
        text,
        r"  /// The release's APK for the device's preferred ABI, first match wins\.\n"
        r"  static String\? _apkFor\(.*?\n  \}\n\}",
        """  /// The release's APK for the device's preferred ABI, first match wins.
  static ReleaseAsset? _apkFor(ReleaseInfo release, List<String> abis) {
    for (final abi in abis) {
      for (final asset in release.assets) {
        if (asset.name.endsWith('.apk') && asset.name.contains(abi)) {
          return asset;
        }
      }
    }
    return null;
  }
}""",
        "android apk picker",
    )
    write(path, text)


def install_overlay(src: pathlib.Path) -> None:
    for source in OVERLAY.rglob("*"):
        if not source.is_file():
            continue
        target = src / source.relative_to(OVERLAY)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


def write_version_code(src: pathlib.Path, version_code: int) -> None:
    if not 1 <= version_code <= 2_100_000_000:
        raise PatchError(f"versionCode out of range: {version_code}")
    (src / "android/version-code.txt").write_text(f"{version_code}\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", required=True, type=pathlib.Path)
    parser.add_argument("--application-id", required=True)
    parser.add_argument("--app-name", default="Mithka")
    parser.add_argument("--update-owner", required=True)
    parser.add_argument("--update-repo", required=True)
    parser.add_argument("--version-code", required=True, type=int)
    args = parser.parse_args()

    src: pathlib.Path = args.src.resolve()
    try:
        install_overlay(src)
        patch_application_id(src, args.application_id)
        patch_manifest_label(src, args.app_name)
        patch_release_feed(src, args.update_owner, args.update_repo)
        patch_update_checker(src)
        write_version_code(src, args.version_code)
    except PatchError as error:
        print(f"patch failed: {error}", file=sys.stderr)
        print(
            "upstream moved the code this builder patches; update patches/apply.py",
            file=sys.stderr,
        )
        return 1

    print(f"patched {src} -> {args.application_id} (versionCode {args.version_code})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
