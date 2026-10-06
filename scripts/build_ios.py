import argparse
import base64
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime
from pathlib import Path
from build_python_runtime import prepare_ios

from app_build import BuildVariant, add_variant_argument, source_access_flags

root = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    subprocess.run(arguments, cwd=kwargs.pop('cwd', root), check=True, **kwargs)


def legacy_session_flags(path=None, required=False):
    raw = path.expanduser().read_bytes() if path else os.environ.get('HUANGGUO_LEGACY_SESSION', '').encode('utf-8')
    if not raw:
        if required:
            raise SystemExit('缺少黄果旧版会话，请提供 --legacy-session 或 HUANGGUO_LEGACY_SESSION。')
        return ''
    if len(raw) > 16 * 1024:
        raise SystemExit('黄果旧版会话超过 16 KiB。')
    try:
        state = json.loads(raw)
        if not isinstance(state, dict):
            raise ValueError('invalid session object')
        valid = (
            state.get('version') == 1
            and state.get('scope') == 'https://dr6skssi3nxbk.cloudfront.net'
            and isinstance(state.get('deviceId'), str)
            and re.fullmatch(r'[A-Fa-f0-9]{16}[0-9]{13}', state['deviceId'])
            and isinstance(state.get('token'), str) and 0 < len(state['token']) <= 4096
            and not any(char in state['token'] for char in '\r\n\t ')
        )
        protocol = state.get('protocol', {})
        valid = valid and isinstance(protocol, dict) and all(
            isinstance(protocol.get(key, ''), str) for key in ('interfaceKey', 'paramKey', 'paramIV')
        )
        if 'updatedAt' in state:
            updated = datetime.fromisoformat(state['updatedAt'])
            valid = valid and updated.tzinfo is not None
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise SystemExit('黄果旧版会话格式无效，需要有效令牌、设备标识及正确接口范围。')
    state = {key: state[key] for key in ('version', 'scope', 'deviceId', 'token', 'protocol', 'updatedAt') if key in state}
    raw = json.dumps(state, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    encoded = base64.b64encode(raw).decode('ascii')
    return ' -X duanjuapp/native/core.bundledLegacySessionBase64=' + encoded


def build_core(simulator=False, variant=BuildVariant(), session_flags=''):
    if platform.system() != 'Darwin':
        raise SystemExit('iOS 构建需要 macOS 和完整 Xcode。')
    go = shutil.which('go')
    if not go:
        raise SystemExit('请安装 Go 1.24.1 或更新版本。')
    environment = os.environ.copy()
    environment.setdefault('GOPROXY', 'https://goproxy.cn,direct')
    environment.setdefault('GOSUMDB', 'off')
    environment['CGO_ENABLED'] = '1'
    environment['GOTOOLCHAIN'] = os.environ.get('GOTOOLCHAIN', 'auto')
    slices = [('iphoneos', 'arm64', 'arm64-apple-ios15.1')]
    if simulator:
        slices.extend([
            ('iphonesimulator', 'arm64', 'arm64-apple-ios15.1-simulator'),
            ('iphonesimulator', 'amd64', 'x86_64-apple-ios15.1-simulator'),
        ])
    libraries = []
    for sdk, architecture, triple in slices:
        sdk_path = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        compiler = subprocess.check_output(['xcrun', '--sdk', sdk, '--find', 'clang'], text=True).strip()
        directory = root / 'native' / 'build' / 'ios' / f'{sdk}-{architecture}'
        headers = directory / 'Headers'
        headers.mkdir(parents=True, exist_ok=True)
        output = directory / 'libDuanjuCore.a'
        flags = shlex.join(['-isysroot', sdk_path, '-target', triple])
        build_env = environment | {
            'GOOS': 'ios', 'GOARCH': architecture, 'CC': compiler,
            'CGO_CFLAGS': flags, 'CGO_LDFLAGS': flags,
        }
        try:
            run([go, 'build', '-trimpath', '-buildmode=c-archive', '-ldflags=' + variant.linker_flags + session_flags,
                 '-o', str(output), './bridge'], cwd=root / 'native', env=build_env)
        except subprocess.CalledProcessError as error:
            if session_flags:
                raise SystemExit(f'iOS 核心编译失败，退出码 {error.returncode}；构建参数中的授权配置已隐藏。') from None
            raise
        shutil.copy2(output.with_suffix('.h'), headers / 'DuanjuCore.h')
        libraries.append((sdk, output, headers))
    arguments = ['xcodebuild', '-create-xcframework']
    device = libraries[0]
    arguments.extend(['-library', str(device[1]), '-headers', str(device[2])])
    if simulator:
        universal = root / 'native' / 'build' / 'ios' / 'simulator-universal'
        universal.mkdir(parents=True, exist_ok=True)
        archive = universal / 'libDuanjuCore.a'
        run(['xcrun', 'lipo', '-create', str(libraries[1][1]), str(libraries[2][1]), '-output', str(archive)])
        arguments.extend(['-library', str(archive), '-headers', str(libraries[1][2])])
    framework = root / 'ios' / 'DuanjuCore' / 'DuanjuCore.xcframework'
    if framework.exists():
        shutil.rmtree(framework)
    run(arguments + ['-output', str(framework)])


def main():
    parser = argparse.ArgumentParser(description='构建红果鉴 / 真果鉴 iOS 核心和应用')
    parser.add_argument('--core-only', action='store_true')
    parser.add_argument('--simulator', action='store_true', help='额外生成模拟器核心；不启动模拟器')
    parser.add_argument('--export-options', type=Path, help='使用自己的 Xcode 签名配置导出 IPA')
    parser.add_argument('--legacy-session', type=Path, help='将指定的黄果旧版会话内置到 IPA；不要提交会话文件')
    parser.add_argument('--require-legacy-session', action='store_true', help='没有有效黄果旧版会话时停止构建')
    parser.add_argument('--source-access', type=Path, help='将指定站源授权内置到应用；不要提交授权文件')
    parser.add_argument('--require-source-access', action='store_true', help='缺少站源授权时停止构建')
    add_variant_argument(parser)
    options = parser.parse_args()
    variant = BuildVariant(options.all_sources)
    session_flags = legacy_session_flags(options.legacy_session, options.require_legacy_session)
    if session_flags and not options.all_sources:
        raise SystemExit('内置黄果旧版会话需要 --all-sources。')
    print('黄果旧版内置会话：' + ('已提供' if session_flags else '未提供'))
    access_flags = source_access_flags(options.source_access, options.require_source_access) if options.all_sources else ''
    if not options.all_sources and (options.source_access or options.require_source_access):
        raise SystemExit('内置站源授权需要 --all-sources。')
    print('附件站源内置授权：' + ('已提供' if access_flags else '未提供'))
    build_core(options.simulator, variant, session_flags + access_flags)
    if options.core_only:
        return
    prepare_ios(options.simulator)
    flutter = shutil.which('flutter')
    if not flutter or not shutil.which('pod'):
        raise SystemExit('请安装 Flutter 和 CocoaPods。')
    run([flutter, 'pub', 'get', '--enforce-lockfile'])
    run(['pod', 'install'], cwd=root / 'ios')
    output = root / 'dist' / 'ios'
    output.mkdir(parents=True, exist_ok=True)
    version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.MULTILINE).group(1)
    artifacts = []
    if options.export_options:
        config = options.export_options.expanduser().resolve()
        if not config.is_file():
            raise SystemExit('ExportOptions.plist 不存在。')
        run([flutter, 'build', 'ipa', '--release', '--no-pub', '--export-options-plist', str(config), *variant.flutter_arguments])
        for package in (root / 'build' / 'ios' / 'ipa').glob('*.ipa'):
            destination = output / f'{variant.slug}-{version}-ios.ipa'
            shutil.copy2(package, destination)
            artifacts.append(destination)
    else:
        run([flutter, 'build', 'ios', '--release', '--no-codesign', '--no-pub', *variant.flutter_arguments])
        application = root / 'build' / 'ios' / 'iphoneos' / 'Runner.app'
        symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(application / 'Runner')], text=True)
        for symbol in ['_DuanjuRequest', '_DuanjuFree']:
            if symbol not in symbols:
                raise SystemExit('iOS 包缺少 FFI 入口：' + symbol)
        destination = output / f'{variant.slug}-{version}-ios-unsigned-app.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(application), str(destination)])
        artifacts.append(destination)
        # 额外打包未签名 IPA：IPA 结构为 zip 内 Payload/Runner.app。
        # 便于用户用 AltStore / Sideloadly / TrollStore 自签后直接安装。
        payload = output / 'Payload'
        if payload.exists():
            shutil.rmtree(payload)
        payload.mkdir(parents=True)
        shutil.copytree(application, payload / application.name, symlinks=True)
        ipa = output / f'{variant.slug}-{version}-ios-unsigned.ipa'
        if ipa.exists():
            ipa.unlink()
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(ipa)])
        with zipfile.ZipFile(ipa) as package:
            for name in ['Payload/Runner.app/Info.plist', 'Payload/Runner.app/Runner']:
                if name not in package.namelist():
                    raise SystemExit('IPA 结构不完整：缺少 ' + name)
        shutil.rmtree(payload)
        artifacts.append(ipa)
    if not artifacts:
        raise SystemExit('未生成 iOS 安装包。')
    checksums = []
    for artifact in sorted(output.glob(f'*-{version}-ios*')):
        digest = hashlib.sha256()
        with artifact.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        checksums.append(f'{digest.hexdigest()}  {artifact.name}')
        print(artifact)
    (output / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n', encoding='ascii')


if __name__ == '__main__':
    main()
