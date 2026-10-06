import os
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    destination = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['FULL_PRODUCT_NAME']
    framework = ROOT / 'ios/PythonRuntime/Python.xcframework'
    platform = os.environ.get('PLATFORM_NAME', 'iphoneos')
    architecture = os.environ.get('CURRENT_ARCH', 'arm64')
    if architecture not in {'arm64', 'x86_64'}:
        architecture = os.environ.get('ARCHS', 'arm64').split()[0]
    folder = 'ios-arm64' if platform == 'iphoneos' else 'ios-arm64_x86_64-simulator'
    packages = ROOT / 'native/build/python-runtime/ios' / (platform + '-' + architecture) / 'site-packages'
    if not packages.is_dir() or not (framework / folder).is_dir():
        raise SystemExit('缺少 Python 运行环境，请先运行 scripts/build_python_runtime.py --platform ios；模拟器增加 --simulator')
    home = destination / 'python'
    if home.exists():
        if home.parent != destination:
            raise SystemExit('Python 资源目录无效')
        shutil.rmtree(home)
    home.mkdir(parents=True)
    shutil.copytree(framework / 'lib', home / 'lib', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('test', 'tests', '__pycache__', 'libpython*.dylib'))
    shutil.copytree(framework / folder / ('lib-' + architecture), home / 'lib', dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('test', 'tests', '__pycache__', 'libpython*.dylib'))
    package_destination = home / 'lib/python3.14/site-packages'
    shutil.copytree(packages, package_destination, dirs_exist_ok=True)
    shutil.copy2(ROOT / 'assets/python_sources/guo_spider.py', home / 'guo_spider.py')
    shutil.copy2(ROOT / 'assets/python_sources/licenses.txt', home / 'licenses.txt')
    frameworks = destination / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '')
    signing = os.environ.get('CODE_SIGNING_ALLOWED', 'YES') != 'NO' and bool(identity)
    bundle = os.environ.get('PRODUCT_BUNDLE_IDENTIFIER', 'com.duanju.duanjuApp')
    bases = [home / 'lib/python3.14/lib-dynload', package_destination]
    for base in bases:
        for binary in base.rglob('*.so'):
            relative = binary.relative_to(base)
            name = '.'.join([*relative.parts[:-1], binary.name.split('.')[0]])
            target = frameworks / (name + '.framework')
            target.mkdir(exist_ok=True)
            executable = target / name
            shutil.copy2(binary, executable)
            subprocess.run(['xcrun', 'install_name_tool', '-id', '@rpath/' + name + '.framework/' + name, str(executable)], check=True)
            with (target / 'Info.plist').open('wb') as output:
                plistlib.dump({'CFBundleExecutable': name, 'CFBundleIdentifier': (bundle + '.python.' + name).replace('_', '-'),
                               'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1',
                               'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.1',
                               'CFBundleSupportedPlatforms': ['iPhoneOS' if platform == 'iphoneos' else 'iPhoneSimulator']}, output)
            marker = binary.with_suffix('.fwork')
            marker.write_text('Frameworks/' + target.name + '/' + name + '\n', encoding='utf-8')
            (target / (name + '.origin')).write_text(marker.relative_to(destination).as_posix() + '\n', encoding='utf-8')
            privacy = binary.parent / (binary.name.split('.')[0] + '.xcprivacy')
            if privacy.exists():
                shutil.copy2(privacy, target / 'PrivacyInfo.xcprivacy')
            binary.unlink()
            if signing:
                subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(target)], check=True)


if __name__ == '__main__':
    main()
