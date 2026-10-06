import argparse
import hashlib
import json
import os
import platform
import runpy
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / 'native' / 'build' / 'python-downloads'
BUILD = ROOT / 'native' / 'build' / 'python-runtime'
PYTHON_MINOR = '3.14'
RUNTIMES = {
    'windows': ('https://www.python.org/ftp/python/3.14.8/python-3.14.8-embed-amd64.zip',
                'a93abe456ab01bd96d7a085b3cdb6566b3063f4241360d114142fbdb07f0a310'),
    'ios': ('https://github.com/beeware/Python-Apple-support/releases/download/3.14-b12/Python-3.14-iOS-support.b12.tar.gz',
            '157a6b956f47a12f005ad1e23e3e264536ef06dd35e1366acb48edbaa128e0a3'),
    'arm64-v8a': ('https://www.python.org/ftp/python/3.14.8/python-3.14.8-aarch64-linux-android.tar.gz',
                  '11324313957da3736f44e90257304d288864321a4dd376ed0cc35a54eacf9a33'),
    'x86_64': ('https://www.python.org/ftp/python/3.14.8/python-3.14.8-x86_64-linux-android.tar.gz',
               '58eb3b2d76ef57e076985a0a6b093cf08906d65ea4ab78cccc6d894d4250c972'),
}
PURE_PACKAGES = {
    'requests': '2.32.5', 'urllib3': '2.5.0', 'idna': '3.10',
    'charset-normalizer': '3.4.3', 'certifi': '2025.8.3', 'PySocks': '1.7.1',
    'beautifulsoup4': '4.13.5', 'soupsieve': '2.8', 'typing-extensions': '4.15.0',
    'pyquery': '2.0.1', 'cssselect': '1.3.0',
}
NATIVE_PACKAGES = {'lxml': '6.0.2', 'pycryptodome': '3.23.0'}


def run(arguments, **kwargs):
    subprocess.run([str(arg) for arg in arguments], check=True, **kwargs)


def fetch(url, digest):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / url.rsplit('/', 1)[1]
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        temporary = path.with_suffix(path.suffix + '.download')
        print('Downloading ' + path.name, flush=True)
        with urllib.request.urlopen(url, timeout=60) as source, temporary.open('wb') as destination:
            shutil.copyfileobj(source, destination)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
            raise RuntimeError('下载校验失败：' + path.name)
        temporary.replace(path)
    return path


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                target = (destination / name).resolve()
                if not target.is_relative_to(destination.resolve()):
                    raise RuntimeError('压缩包路径无效')
            package.extractall(destination)
    else:
        with tarfile.open(archive) as package:
            package.extractall(destination, filter='data')


def pypi_release(name, version):
    with urllib.request.urlopen(f'https://pypi.org/pypi/{name}/{version}/json', timeout=30) as response:
        return json.load(response)['urls']


def package_archive(name, version, predicate):
    matches = [item for item in pypi_release(name, version) if predicate(item)]
    if not matches:
        raise RuntimeError(f'缺少兼容的依赖构建输入：{name}=={version}')
    item = matches[0]
    return fetch(item['url'], item['digests']['sha256'])


def install_pure(destination):
    destination.mkdir(parents=True, exist_ok=True)
    for name, version in PURE_PACKAGES.items():
        archive = package_archive(name, version, lambda item: item['filename'].endswith('-none-any.whl'))
        extract(archive, destination)


def install_runner(home):
    shutil.copy2(ROOT / 'assets' / 'python_sources' / 'guo_spider.py', home / 'guo_spider.py')
    manifest = {'python': PYTHON_MINOR, 'runtime': RUNTIMES,
                'packages': PURE_PACKAGES | NATIVE_PACKAGES,
                'runner': hashlib.sha256((home / 'guo_spider.py').read_bytes()).hexdigest()}
    (home / 'runtime.json').write_text(json.dumps(manifest, sort_keys=True), encoding='utf-8')
    shutil.copy2(ROOT / 'assets/python_sources/licenses.txt', home / 'licenses.txt')


def source_tree(name, version, directory):
    archive = package_archive(name, version, lambda item: item['packagetype'] == 'sdist')
    target = directory / name
    if not target.exists():
        temporary = directory / (name + '-source')
        extract(archive, temporary)
        children = list(temporary.iterdir())
        if len(children) != 1 or not children[0].is_dir():
            raise RuntimeError('依赖源码目录无效：' + name)
        children[0].rename(target)
    return target


def gnome_source(name, version, directory):
    url = f'https://download.gnome.org/sources/{name}/{".".join(version.split(".")[:2])}/{name}-{version}.tar.xz'
    with urllib.request.urlopen(url.rsplit('/', 1)[0] + f'/{name}-{version}.sha256sum', timeout=30) as response:
        lines = response.read().decode().splitlines()
    digest = next(line.split()[0] for line in lines if line.endswith(f'{name}-{version}.tar.xz'))
    archive = fetch(url, digest)
    target = directory / f'{name}-{version}'
    if not target.exists():
        extract(archive, directory)
    return target


def compile_extensions(key, target, packages, compiler, flags, host, framework=None):
    if platform.system() == 'Windows':
        raise RuntimeError('Android Python 原生依赖需要 Linux/macOS 构建主机；Windows 应用使用预编译 wheel')
    directory = BUILD / ('extensions-' + key)
    directory.mkdir(parents=True, exist_ok=True)
    marker = directory / 'complete.json'
    expected = {'packages': NATIVE_PACKAGES, 'runtime': list(RUNTIMES['ios' if framework else key]), 'flags': flags}
    if marker.exists() and json.loads(marker.read_text()) == expected:
        extract(directory / 'packages.zip', packages)
        return
    prefix = directory / 'libraries'
    env = os.environ.copy()
    env.update(CC=compiler, CFLAGS=flags + ' -fPIC -O2', CPPFLAGS=flags,
               LDFLAGS=flags, PKG_CONFIG_PATH=str(prefix / 'lib' / 'pkgconfig'))
    if framework:
        env['AR'] = 'ar'
    else:
        env['AR'] = str(Path(compiler).parent / 'llvm-ar')
        env['RANLIB'] = str(Path(compiler).parent / 'llvm-ranlib')
    for name, version, extra in [
        ('libxml2', '2.12.10', ['--without-python', '--without-lzma', '--without-zlib', '--without-iconv']),
        ('libxslt', '1.1.43', ['--without-python', '--without-crypto', '--without-plugins', '--with-libxml-prefix=' + str(prefix)]),
    ]:
        tree = gnome_source(name, version, directory)
        run(['sh', 'configure', '--host=' + host, '--prefix=' + str(prefix), '--disable-shared', '--enable-static', *extra], cwd=tree, env=env)
        run(['make', '-j', str(min(os.cpu_count() or 2, 8))], cwd=tree, env=env)
        run(['make', 'install'], cwd=tree, env=env)
    tools = BUILD / 'build-tools'
    if not (tools / 'setuptools').exists():
        run([sys.executable, '-m', 'pip', 'install', '--target', tools, 'setuptools==80.9.0', 'wheel==0.45.1'])
    config_files = list(target.rglob('_sysconfigdata*.py'))
    config_files = [p for p in config_files if '/test/' not in p.as_posix()]
    if framework:
        config_files = [p for p in config_files if ('iphonesimulator' if 'simulator' in key else 'iphoneos') in p.name and ('x86_64' if key.endswith('x86_64') else 'arm64') in p.name]
    if not config_files:
        raise RuntimeError('Python 目标平台 sysconfig 缺失')
    variables = runpy.run_path(str(config_files[0]))['build_time_vars']
    include = target / 'include' / 'python3.14'
    linker = compiler + ' ' + flags
    if framework:
        linker += ' -dynamiclib -F' + shlex.quote(str(framework.parent)) + ' -framework Python'
    else:
        linker += ' -shared -L' + shlex.quote(str(target / 'lib')) + ' -lpython3.14'
    variables.update(CC=compiler, CXX=compiler, LDSHARED=linker, BLDSHARED=linker,
                     CFLAGS=flags + ' -fPIC -O2', CCSHARED='-fPIC', LDFLAGS=flags,
                     INCLUDEPY=str(include), CONFINCLUDEPY=str(include),
                     LIBDIR=str(target / 'lib'), prefix=str(target), exec_prefix=str(target),
                     LIBPL=str(target / 'lib'), BINDIR=str(target / 'bin'))
    variables['AR'] = env['AR']
    if 'RANLIB' in env:
        variables['RANLIB'] = env['RANLIB']
    (directory / 'config.json').write_text(json.dumps(variables), encoding='utf-8')
    shim = directory / 'compile.py'
    shim.write_text(
        'import json,os,runpy,sys,sysconfig\n'
        'sys.path.insert(0,sys.argv.pop(1))\n'
        'variables=json.load(open(sys.argv.pop(1)))\n'
        'sysconfig.get_config_vars().update(variables)\n'
        'original=sysconfig.get_paths\n'
        'def paths(*args,**kwargs):\n'
        ' result=original(*args,**kwargs); result["include"]=variables["INCLUDEPY"]; result["platinclude"]=variables["INCLUDEPY"]; return result\n'
        'sysconfig.get_paths=paths\n'
        'sysconfig.get_path=lambda name,*args,**kwargs: paths(*args,**kwargs)[name]\n'
        'sys.argv[0]="setup.py"\n'
        'sys.path.insert(0,os.getcwd())\n'
        'runpy.run_path("setup.py",run_name="__main__")\n', encoding='utf-8')
    env.update(_PYTHON_HOST_PLATFORM=key, PYTHONPATH=str(tools),
               CFLAGS=flags + ' -fPIC -O2 -I' + str(include) + ' -I' + str(prefix / 'include' / 'libxml2'),
               LDSHARED=linker,
               XML2_CONFIG=str(prefix / 'bin' / 'xml2-config'), XSLT_CONFIG=str(prefix / 'bin' / 'xslt-config'))
    assembled = directory / 'assembled'
    assembled.mkdir(exist_ok=True)
    for name, version in NATIVE_PACKAGES.items():
        tree = source_tree(name, version, directory)
        args = [sys.executable, shim, tools, directory / 'config.json', 'build_ext', '--force', '--build-lib', assembled]
        if name == 'lxml':
            args.extend(['--static'])
        run(args, cwd=tree, env=env)
        source = tree / ('src/lxml' if name == 'lxml' else 'lib/Crypto')
        shutil.copytree(source, assembled / ('lxml' if name == 'lxml' else 'Crypto'), dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('*.c', '*.h', '*.pyx', '*.pxd', '*.pxi', 'tests', 'SelfTest', '__pycache__'))
    with zipfile.ZipFile(directory / 'packages.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in assembled.rglob('*'):
            if file.is_file():
                archive.write(file, file.relative_to(assembled).as_posix())
    extract(directory / 'packages.zip', packages)
    marker.write_text(json.dumps(expected), encoding='utf-8')


def prepare_windows():
    home = BUILD / 'windows'
    if home.exists():
        if home.resolve().parent != BUILD.resolve():
            raise RuntimeError('Python 构建目录无效')
        shutil.rmtree(home)
    extract(fetch(*RUNTIMES['windows']), home)
    for file in home.glob('*._pth'):
        file.unlink()
    packages = home / 'Lib' / 'site-packages'
    install_pure(packages)
    for name, version in NATIVE_PACKAGES.items():
        archive = package_archive(name, version, lambda item: item['filename'].endswith('win_amd64.whl') and ('-cp314-cp314-' in item['filename'] or '-abi3-' in item['filename']))
        extract(archive, packages)
    install_runner(home)
    return home


def prepare_android(abis):
    if 'armeabi-v7a' in abis:
        raise RuntimeError('Python 3.14 官方运行时支持 arm64-v8a 和 x86_64，请使用这两个 ABI 构建脚本导入版')
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        raise RuntimeError('请设置 ANDROID_HOME')
    ndk = Path(os.environ.get('ANDROID_NDK_HOME', Path(sdk) / 'ndk' / '28.2.13676358'))
    host = {'Darwin': 'darwin-x86_64', 'Linux': 'linux-x86_64'}.get(platform.system())
    if host is None:
        raise RuntimeError('Android 脚本导入版需要 Linux/macOS 构建主机')
    compilers = ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
    for abi in abis:
        directory = BUILD / ('android-' + abi)
        extract(fetch(*RUNTIMES[abi]), directory)
        target = directory / 'prefix'
        if not target.is_dir():
            raise RuntimeError('Android Python 运行时目录无效')
        triple = 'aarch64-linux-android' if abi == 'arm64-v8a' else 'x86_64-linux-android'
        packages = target / 'lib/python3.14/site-packages'
        install_pure(packages)
        compile_extensions(abi, target, packages, str(compilers / (triple + '26-clang')), '', triple)
        home = directory / 'home'
        shutil.copytree(target / 'lib/python3.14', home / 'lib/python3.14', dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('test', 'tests', '__pycache__'))
        install_runner(home)
        libraries = ROOT / 'android/app/src/main/jniLibs' / abi
        libraries.mkdir(parents=True, exist_ok=True)
        for file in (target / 'lib').glob('*.so*'):
            if file.is_file():
                shutil.copy2(file, libraries / file.name)
        assets = ROOT / 'android/app/src/main/assets/python-runtime'
        assets.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(assets / (abi + '.zip'), 'w', zipfile.ZIP_DEFLATED) as archive:
            for file in home.rglob('*'):
                if file.is_file():
                    archive.write(file, file.relative_to(home).as_posix())


def prepare_ios(simulator=False):
    if platform.system() != 'Darwin':
        raise RuntimeError('iOS Python 原生依赖需要 macOS 和完整 Xcode')
    directory = BUILD / 'ios'
    if not (directory / 'Python.xcframework/Info.plist').exists():
        extract(fetch(*RUNTIMES['ios']), directory)
    framework = directory / 'Python.xcframework'
    slices = [('ios-arm64', 'arm64', 'iphoneos', 'arm64-apple-ios15.1')]
    if simulator:
        slices.extend([('ios-arm64_x86_64-simulator', 'arm64', 'iphonesimulator', 'arm64-apple-ios15.1-simulator'),
                       ('ios-arm64_x86_64-simulator', 'x86_64', 'iphonesimulator', 'x86_64-apple-ios15.1-simulator')])
    for folder, architecture, sdk, triple in slices:
        packages = directory / (sdk + '-' + architecture) / 'site-packages'
        install_pure(packages)
        compiler = subprocess.check_output(['xcrun', '--sdk', sdk, '--find', 'clang'], text=True).strip()
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        flags = shlex.join(['-isysroot', sdk_path, '-target', triple])
        compile_extensions('ios-' + sdk + '-' + architecture, framework / folder, packages,
                           compiler, flags, architecture + '-apple-darwin', framework / folder / 'Python.framework')
    destination = ROOT / 'ios/PythonRuntime/Python.xcframework'
    shutil.copytree(framework, destination, dirs_exist_ok=True)
    return directory


def main():
    parser = argparse.ArgumentParser(description='准备随安装包内置的 Python Spider 运行环境')
    parser.add_argument('--platform', choices=['windows', 'android', 'ios'], required=True)
    parser.add_argument('--abi', action='append', choices=['arm64-v8a', 'x86_64', 'armeabi-v7a'])
    parser.add_argument('--simulator', action='store_true')
    options = parser.parse_args()
    try:
        if options.platform == 'windows':
            prepare_windows()
        elif options.platform == 'android':
            prepare_android(options.abi or ['arm64-v8a', 'x86_64'])
        else:
            prepare_ios(options.simulator)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit('Python 运行环境准备失败：' + str(error)) from None


if __name__ == '__main__':
    main()
