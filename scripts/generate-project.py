#!/usr/bin/env python3
"""Reproducibly generate the checked-in Xcode project; no XcodeGen dependency."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Monarch.xcodeproj"
PROJECT.mkdir(exist_ok=True)
objects = {}


def ident(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def add(name, body):
    key = ident(name)
    objects[key] = body
    return key


def ref(name):
    return ident(name)


def array(values):
    return "(" + ", ".join(values) + ")"


def configuration(name, settings):
    body = " ".join(f"{key} = {quote(value)};" for key, value in settings.items())
    return add(name, f"isa = XCBuildConfiguration; baseConfigurationReference = {ref('config-file')}; buildSettings = {{{body}}}; name = {quote(name.rsplit('-', 1)[1])};")


def config_list(name, settings, release_extra=None):
    debug = configuration(name + "-Debug", {**settings, "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "DEBUG_INFORMATION_FORMAT": "dwarf", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"})
    release = configuration(name + "-Release", {**settings, "SWIFT_OPTIMIZATION_LEVEL": "-O", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", **(release_extra or {})})
    return add(name + "-config-list", f"isa = XCConfigurationList; buildConfigurations = ({debug}, {release}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")


config_file = add("config-file", 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config.xcconfig; sourceTree = SOURCE_ROOT;')
local_package = add("core-package", 'isa = XCLocalSwiftPackageReference; relativePath = MonarchCore;')
plaid_package = add("plaid-package", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/plaid/plaid-link-ios-spm"; requirement = {kind = exactVersion; version = 7.2.3;};')
core_product = add("core-product", f"isa = XCSwiftPackageProductDependency; package = {local_package}; productName = MonarchCore;")
plaid_product = add("plaid-product", f"isa = XCSwiftPackageProductDependency; package = {plaid_package}; productName = LinkKit;")

groups = []
product_refs = []
base_settings = {
    "CLANG_ENABLE_MODULES": "YES", "SWIFT_VERSION": "5.0", "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
    "SDKROOT": "iphoneos", "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "CODE_SIGN_STYLE": "Automatic", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "SWIFT_STRICT_CONCURRENCY": "targeted", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
}
project_config = config_list("project", base_settings)


def target(name, product_type, extension, folder, dependencies, packages, settings, extra_sources=()):
    sources, resources, children = [], [], []
    for path in sorted(list((ROOT / folder).rglob("*.swift")) + [ROOT / path for path in extra_sources]):
        relative = path.relative_to(ROOT).as_posix()
        file_ref = add("file-" + relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;")
        children.append(file_ref)
        sources.append(add(name + "-source-" + relative, f"isa = PBXBuildFile; fileRef = {file_ref};"))
    if name == "Monarch":
        for relative, kind in [("Monarch/Resources/Assets.xcassets", "folder.assetcatalog"), ("Monarch/Resources/PrivacyInfo.xcprivacy", "text.xml")]:
            file_ref = add("file-" + relative, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(relative)}; sourceTree = SOURCE_ROOT;")
            children.append(file_ref)
            resources.append(add("resource-" + relative, f"isa = PBXBuildFile; fileRef = {file_ref};"))
        children.append(add("Info-plist", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Monarch/Resources/Info.plist"; sourceTree = SOURCE_ROOT;'))
    group = add("group-" + name, f"isa = PBXGroup; children = {array(children)}; name = {quote(name)}; sourceTree = \"<group>\";")
    groups.append(group)
    product_kind = 'wrapper.application' if extension == 'app' else 'wrapper.app-extension' if extension == 'appex' else 'wrapper.cfbundle'
    product = add("product-" + name, f"isa = PBXFileReference; explicitFileType = {quote(product_kind)}; includeInIndex = 0; path = {quote(name + '.' + extension)}; sourceTree = BUILT_PRODUCTS_DIR;")
    product_refs.append(product)
    sources_phase = add(name + "-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(sources)}; runOnlyForDeploymentPostprocessing = 0;")
    resources_phase = add(name + "-resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resources)}; runOnlyForDeploymentPostprocessing = 0;")
    frameworks = [add(name + "-framework-" + p, f"isa = PBXBuildFile; productRef = {p};") for p in packages]
    framework_phase = add(name + "-frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {array(frameworks)}; runOnlyForDeploymentPostprocessing = 0;")
    config = config_list(name, {**base_settings, "PRODUCT_NAME": "$(TARGET_NAME)", **settings})
    phases = [sources_phase, framework_phase, resources_phase]
    if name == "Monarch": phases.append(ref("embed-extensions"))
    add(name + "-target", f"isa = PBXNativeTarget; buildConfigurationList = {config}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(dependencies)}; name = {name}; packageProductDependencies = {array(packages)}; productName = {name}; productReference = {product}; productType = {quote(product_type)};")


dependency_proxy = add("app-proxy", f"isa = PBXContainerItemProxy; containerPortal = {ref('project')}; proxyType = 1; remoteGlobalIDString = {ref('Monarch-target')}; remoteInfo = Monarch;")
app_dependency = add("app-dependency", f"isa = PBXTargetDependency; target = {ref('Monarch-target')}; targetProxy = {dependency_proxy};")
extension_dependencies = []
extension_files = []
for extension_name in ["MonarchShare", "MonarchActivity"]:
    proxy = add(extension_name + "-proxy", f"isa = PBXContainerItemProxy; containerPortal = {ref('project')}; proxyType = 1; remoteGlobalIDString = {ref(extension_name + '-target')}; remoteInfo = {extension_name};")
    extension_dependencies.append(add(extension_name + "-dependency", f"isa = PBXTargetDependency; target = {ref(extension_name + '-target')}; targetProxy = {proxy};"))
    extension_files.append(add(extension_name + "-embed", f"isa = PBXBuildFile; fileRef = {ref('product-' + extension_name)}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy);}};"))
add("embed-extensions", f"isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = {array(extension_files)}; name = \"Embed App Extensions\"; runOnlyForDeploymentPostprocessing = 0;")
target("Monarch", "com.apple.product-type.application", "app", "Monarch", extension_dependencies, [core_product, plaid_product], {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.aali.monarch.sandbox", "INFOPLIST_FILE": "Monarch/Resources/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "MARKETING_VERSION": "0.2.0", "CURRENT_PROJECT_VERSION": "2", "ENABLE_PREVIEWS": "YES", "SWIFT_EMIT_LOC_STRINGS": "YES", "CODE_SIGN_ENTITLEMENTS": "Monarch/Resources/Monarch.entitlements",
}, extra_sources=["Shared/SharedInbox.swift", "Shared/ShipmentActivityAttributes.swift"])
target("MonarchShare", "com.apple.product-type.app-extension", "appex", "MonarchShare", [], [], {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.aali.monarch.sandbox.share", "INFOPLIST_FILE": "MonarchShare/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "CODE_SIGN_ENTITLEMENTS": "MonarchShare/MonarchShare.entitlements", "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
}, extra_sources=["Shared/SharedInbox.swift"])
target("MonarchActivity", "com.apple.product-type.app-extension", "appex", "MonarchActivity", [], [], {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.aali.monarch.sandbox.activity", "INFOPLIST_FILE": "MonarchActivity/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
}, extra_sources=["Shared/ShipmentActivityAttributes.swift"])
target("MonarchTests", "com.apple.product-type.bundle.unit-test", "xctest", "MonarchTests", [app_dependency], [core_product], {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.aali.monarch.sandbox.tests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Monarch.app/Monarch", "BUNDLE_LOADER": "$(TEST_HOST)", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
})
target("MonarchUITests", "com.apple.product-type.bundle.ui-testing", "xctest", "MonarchUITests", [app_dependency], [], {
    "PRODUCT_BUNDLE_IDENTIFIER": "com.aali.monarch.sandbox.uitests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_TARGET_NAME": "Monarch",
})
products_group = add("products-group", f"isa = PBXGroup; children = {array(product_refs)}; name = Products; sourceTree = \"<group>\";")
main_group = add("main-group", f"isa = PBXGroup; children = {array(groups + [products_group, config_file])}; sourceTree = \"<group>\";")
add("project", f"isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{{ref('Monarch-target')} = {{CreatedOnToolsVersion = 26.0;}}; {ref('MonarchTests-target')} = {{CreatedOnToolsVersion = 26.0; TestTargetID = {ref('Monarch-target')};}}; {ref('MonarchUITests-target')} = {{CreatedOnToolsVersion = 26.0; TestTargetID = {ref('Monarch-target')};}};}};}}; buildConfigurationList = {project_config}; compatibilityVersion = \"Xcode 15.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; packageReferences = ({local_package}, {plaid_package}); productRefGroup = {products_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({ref('Monarch-target')}, {ref('MonarchShare-target')}, {ref('MonarchActivity-target')}, {ref('MonarchTests-target')}, {ref('MonarchUITests-target')});")
lines = ["// !$*UTF8*$!", "{", "archiveVersion = 1;", "classes = {};", "objectVersion = 60;", "objects = {"]
lines.extend(f"{key} = {{{body}}};" for key, body in sorted(objects.items()))
lines.extend(["};", f"rootObject = {ref('project')};", "}"])
(PROJECT / "project.pbxproj").write_text("\n".join(lines) + "\n")
scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)


def buildable(name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(name + "-target")}" BuildableName="{name}.{("app" if name == "Monarch" else "xctest")}" BlueprintName="{name}" ReferencedContainer="container:Monarch.xcodeproj"/>'


scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable("Monarch")}</BuildActionEntry>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{buildable("MonarchTests")}</BuildActionEntry>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{buildable("MonarchUITests")}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
  <TestableReference skipped="NO">{buildable("MonarchTests")}</TestableReference>
  <TestableReference skipped="NO">{buildable("MonarchUITests")}</TestableReference>
 </Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("Monarch")}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable("Monarch")}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_dir / "Monarch.xcscheme").write_text(scheme)
print(f"Generated {PROJECT.name} with {len(objects)} objects")
