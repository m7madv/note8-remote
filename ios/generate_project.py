#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; works on Windows and macOS."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent
project=root/'Note8Remote.xcodeproj'
project.mkdir(exist_ok=True)
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
objects=[]
def obj(name,body): objects.append(f'{uid(name)} = {{ {body} }};');return uid(name)
sources=sorted((root/'Note8Remote').glob('*.swift'))
refs=[];builds=[]
for f in sources:
    refs.append(obj('ref:'+f.name,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Note8Remote/{f.name}"; sourceTree = "<group>";'))
    builds.append(obj('build:'+f.name,f'isa = PBXBuildFile; fileRef = {refs[-1]};'))
asset=obj('assets','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Note8Remote/Assets.xcassets; sourceTree = "<group>";')
assetbuild=obj('assetbuild',f'isa = PBXBuildFile; fileRef = {asset};')
privacy=obj('privacy','isa = PBXFileReference; lastKnownFileType = text.xml; path = Note8Remote/PrivacyInfo.xcprivacy; sourceTree = "<group>";')
privacybuild=obj('privacybuild',f'isa = PBXBuildFile; fileRef = {privacy};')
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = Note8Remote.app; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group=obj('rootgroup',f'isa = PBXGroup; children = ({",".join(refs)},{asset},{privacy},{products},); sourceTree = "<group>";')
sourcephase=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
resourcephase=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assetbuild},{privacybuild},); runOnlyForDeploymentPostprocessing = 0;')
frameworkphase=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs=[];pconfigs=[]
for mode in ['Debug','Release']:
    configs.append(obj('config:'+mode, f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = Note8Remote; PRODUCT_BUNDLE_IDENTIFIER = com.mohammad.note8remote;
        INFOPLIST_FILE = Note8Remote/Info.plist; GENERATE_INFOPLIST_FILE = NO;
        SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 16.0; TARGETED_DEVICE_FAMILY = "1,2";
        ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
        CODE_SIGN_STYLE = Automatic; ENABLE_USER_SCRIPT_SANDBOXING = YES;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if mode=='Debug' else '-O'}";
    }};'''))
    pconfigs.append(obj('pconfig:'+mode,f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ SDKROOT = iphoneos; CLANG_ENABLE_MODULES = YES; }};'))
cl=obj('configlist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
pcl=obj('pconfiglist',f'isa = XCConfigurationList; buildConfigurations = ({",".join(pconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({sourcephase},{frameworkphase},{resourcephase},); buildRules = (); dependencies = (); name = Note8Remote; productName = Note8Remote; productReference = {product}; productType = "com.apple.product-type.application";')
proj=obj('project',f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ar; knownRegions = (ar,en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+proj+'; }\n')
schemes=project/'xcshareddata'/'xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'Note8Remote.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Note8Remote.app" BlueprintName="Note8Remote" ReferencedContainer="container:Note8Remote.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Note8Remote.app" BlueprintName="Note8Remote" ReferencedContainer="container:Note8Remote.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
assets=root/'Note8Remote'/'Assets.xcassets';assets.mkdir(exist_ok=True)
(assets/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
accent=assets/'AccentColor.colorset';accent.mkdir(exist_ok=True)
(accent/'Contents.json').write_text(json.dumps({'colors':[{'idiom':'universal','color':{'color-space':'srgb','components':{'red':'0.090','green':'0.420','blue':'0.345','alpha':'1.000'}}},{'idiom':'universal','appearances':[{'appearance':'luminosity','value':'dark'}],'color':{'color-space':'srgb','components':{'red':'0.345','green':'0.800','blue':'0.651','alpha':'1.000'}}}],'info':{'author':'xcode','version':1}}))
print('Generated',project)
