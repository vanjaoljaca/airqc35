const root = dirname(fileURLToPath(import.meta.url));
const objects: Record<string, any> = {};
const id = (name: string) => createHash('sha256').update(name).digest('hex').slice(0, 24).toUpperCase();
function object(name: string, value: any) { const key = id(name); objects[key] = value; return key; }
function file(path: string, type = 'sourcecode.swift') {
  return object(path, { isa: 'PBXFileReference', lastKnownFileType: type, path, sourceTree: '<group>' });
}
function sources(name: string, paths: string[]) {
  return object(name, { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, runOnlyForDeploymentPostprocessing: 0,
    files: paths.map(path => object(name + path, { isa: 'PBXBuildFile', fileRef: file(path) })) });
}
function configs(name: string, settings: any) {
  return object(name + 'configs', { isa: 'XCConfigurationList', defaultConfigurationName: 'Debug', defaultConfigurationIsVisible: 0,
    buildConfigurations: ['Debug', 'Release'].map(config => object(name + config, {
      isa: 'XCBuildConfiguration', name: config, buildSettings: settings })) });
}
function target(name: string, product: string, bundle: string, type: string, paths: string[], extras: any) {
  return object(name, { isa: 'PBXNativeTarget', name, productName: product, productType: type,
    productReference: object(name + 'product', { isa: 'PBXFileReference', explicitFileType: type.endsWith('app-extension') ? 'wrapper.app-extension' : 'wrapper.application', path: product + (type.endsWith('app-extension') ? '.appex' : '.app'), sourceTree: 'BUILT_PRODUCTS_DIR' }),
    buildConfigurationList: configs(name, { PRODUCT_NAME: product, PRODUCT_BUNDLE_IDENTIFIER: bundle, INFOPLIST_FILE: name + '.plist', CODE_SIGN_IDENTITY: '-', CODE_SIGN_STYLE: 'Manual', SWIFT_VERSION: '5.0', SWIFT_TREAT_WARNINGS_AS_ERRORS: 'YES', MACOSX_DEPLOYMENT_TARGET: '27.0', GENERATE_INFOPLIST_FILE: 'NO', ENABLE_HARDENED_RUNTIME: 'YES', ...extras }),
    buildPhases: [sources(name + 'sources', paths)], buildRules: [], dependencies: [] });
}
const widget = target('QC35Widget', 'QC35Widget', 'com.vanja.qc35.control.widget', 'com.apple.product-type.app-extension', ['Widget/QC35Control.swift', 'Shared/OpenQC35Intent.swift'], {
  SKIP_INSTALL: 'YES', APPLICATION_EXTENSION_API_ONLY: 'YES', ENABLE_APP_SANDBOX: 'YES', CODE_SIGN_ENTITLEMENTS: 'Widget.entitlements', SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'WIDGET_EXTENSION' });
const host = target('QC35', 'QC35', 'com.vanja.qc35.control', 'com.apple.product-type.application', ['App/QC35ControlApp.swift', 'App/QC35View.swift', 'App/QC35Model.swift', 'App/BoseSources.swift', 'App/MacConnection.swift', 'Shared/OpenQC35Intent.swift'], { ENABLE_APP_SANDBOX: 'NO' });
objects[host].dependencies.push(object('widgetdependency', { isa: 'PBXTargetDependency', target: widget, targetProxy: object('widgetproxy', { isa: 'PBXContainerItemProxy', containerPortal: id('project'), proxyType: 1, remoteGlobalIDString: widget, remoteInfo: 'QC35Widget' }) }));
objects[host].buildPhases.push(object('embed', { isa: 'PBXCopyFilesBuildPhase', buildActionMask: 2147483647, dstPath: '', dstSubfolderSpec: 13, name: 'Embed App Extensions', runOnlyForDeploymentPostprocessing: 0,
  files: [object('embedwidget', { isa: 'PBXBuildFile', fileRef: id('QC35Widgetproduct'), settings: { ATTRIBUTES: ['RemoveHeadersOnCopy'] } })] }));
const productGroup = object('products', { isa: 'PBXGroup', children: [id('QC35product'), id('QC35Widgetproduct')], name: 'Products', sourceTree: '<group>' });
const mainGroup = object('main', { isa: 'PBXGroup', children: [...new Set(Object.entries(objects).filter(([,o]) => o.isa === 'PBXFileReference' && o.sourceTree === '<group>').map(([key]) => key)), productGroup], sourceTree: '<group>' });
object('project', { isa: 'PBXProject', attributes: { LastUpgradeCheck: '2700' }, buildConfigurationList: configs('project', { SDKROOT: 'macosx', CLANG_ENABLE_MODULES: 'YES' }), compatibilityVersion: 'Xcode 14.0', developmentRegion: 'en', knownRegions: ['en', 'Base'], mainGroup, productRefGroup: productGroup, projectDirPath: '', projectRoot: '', targets: [host, widget] });
function plist(path: string, data: any) {
  const temp = join(root, path + '.json');
  writeFileSync(temp, JSON.stringify(data, (_key, value) => path.endsWith(".pbxproj") && (typeof value === "number" || typeof value === "boolean") ? String(value) : value));
  execFileSync('/usr/bin/plutil', ['-convert', 'xml1', '-o', join(root, path), temp]);
  unlinkSync(temp);
}
mkdirSync(join(root, 'QC35.xcodeproj'), { recursive: true });
plist('QC35.xcodeproj/project.pbxproj', { archiveVersion: 1, classes: {}, objectVersion: 56, objects, rootObject: id('project') });
const info = { CFBundleDevelopmentRegion: 'en', CFBundleExecutable: '$(EXECUTABLE_NAME)', CFBundleIdentifier: '$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleName: '$(PRODUCT_NAME)', CFBundleDisplayName: 'QC35', CFBundleShortVersionString: '1.0', CFBundleVersion: '1', LSMinimumSystemVersion: '27.0' };
plist('QC35.plist', { ...info, CFBundlePackageType: 'APPL', NSPrincipalClass: 'NSApplication', LSUIElement: true, NSBluetoothAlwaysUsageDescription: 'Read QC35 paired devices and reconnect the device you choose.' });
plist('QC35Widget.plist', { ...info, CFBundlePackageType: 'XPC!', NSExtension: { NSExtensionPointIdentifier: 'com.apple.widgetkit-extension' } });
plist('Widget.entitlements', { 'com.apple.security.app-sandbox': true });
console.log(JSON.stringify({ event: 'qc35_project_generated', root }));

import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync, writeFileSync, unlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
