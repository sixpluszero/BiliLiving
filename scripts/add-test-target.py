from pathlib import Path
import xml.etree.ElementTree as ET
p=Path('BilibiliLive.xcodeproj/project.pbxproj')
s=p.read_text()
if 'BA0000000000000000000001' not in s:
    objects='''
BA0000000000000000000001 = { isa = PBXNativeTarget; buildConfigurationList = BA0000000000000000000002; buildPhases = (BA0000000000000000000005, BA0000000000000000000006, ); buildRules = (); dependencies = (BA000000000000000000000A, ); name = BiliLivingTests; productName = BiliLivingTests; productReference = BA0000000000000000000007; productType = "com.apple.product-type.bundle.unit-test"; };
BA0000000000000000000002 = { isa = XCConfigurationList; buildConfigurations = (BA0000000000000000000003, BA0000000000000000000004, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
BA0000000000000000000003 = { isa = XCBuildConfiguration; buildSettings = { BUNDLE_LOADER = "$(TEST_HOST)"; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.jialin.BiliLivingTests; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = appletvos; SUPPORTED_PLATFORMS = "appletvos appletvsimulator"; TARGETED_DEVICE_FAMILY = 3; TVOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/BilibiliLive.app/BilibiliLive"; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks", ); }; name = Debug; };
BA0000000000000000000004 = { isa = XCBuildConfiguration; buildSettings = { BUNDLE_LOADER = "$(TEST_HOST)"; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.jialin.BiliLivingTests; PRODUCT_NAME = "$(TARGET_NAME)"; SDKROOT = appletvos; SUPPORTED_PLATFORMS = "appletvos appletvsimulator"; TARGETED_DEVICE_FAMILY = 3; TVOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/BilibiliLive.app/BilibiliLive"; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks", ); }; name = Release; };
BA0000000000000000000005 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (BA0000000000000000000009, ); runOnlyForDeploymentPostprocessing = 0; };
BA0000000000000000000006 = { isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
BA0000000000000000000007 = { isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = BiliLivingTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
BA0000000000000000000008 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/BiliLivingTests.swift; sourceTree = SOURCE_ROOT; };
BA0000000000000000000009 = { isa = PBXBuildFile; fileRef = BA0000000000000000000008; };
BA000000000000000000000A = { isa = PBXTargetDependency; target = F9B5734F260F5F7400771ED5; targetProxy = BA000000000000000000000B; };
BA000000000000000000000B = { isa = PBXContainerItemProxy; containerPortal = F9B57348260F5F7400771ED5; proxyType = 1; remoteGlobalIDString = F9B5734F260F5F7400771ED5; remoteInfo = BilibiliLive; };
'''
    # Read actual project ID rather than assume it.
    import re
    project_id=re.search(r'rootObject = ([A-F0-9]+)',s).group(1)
    objects=objects.replace('F9B57348260F5F7400771ED5',project_id)
    s=s.replace('objects = {','objects = {'+objects,1).replace('targets = (','targets = (\n BA0000000000000000000001,',1)
    s=s.replace('4930B8FD2D686DC30074E861 /* BilibiliLive */,','4930B8FD2D686DC30074E861 /* BilibiliLive */,\n BA0000000000000000000008,',1)
    p.write_text(s)
p=Path('BilibiliLive.xcodeproj/xcshareddata/xcschemes/BilibiliLive.xcscheme')
t=ET.parse(p);root=t.getroot();a=root.find('TestAction')
if a is None: a=ET.SubElement(root,'TestAction',{'buildConfiguration':'Debug','selectedDebuggerIdentifier':'Xcode.DebuggerFoundation.Debugger.LLDB','selectedLauncherIdentifier':'Xcode.IDEFoundation.Launcher.LLDB','shouldUseLaunchSchemeArgsEnv':'YES'})
tests=a.find('Testables')
if tests is None: tests=ET.SubElement(a,'Testables')
if not list(tests):
    item=ET.SubElement(tests,'TestableReference',{'skipped':'NO'})
    ET.SubElement(item,'BuildableReference',{'BuildableIdentifier':'primary','BlueprintIdentifier':'BA0000000000000000000001','BuildableName':'BiliLivingTests.xctest','BlueprintName':'BiliLivingTests','ReferencedContainer':'container:BilibiliLive.xcodeproj'})
ET.indent(t);t.write(p,encoding='UTF-8',xml_declaration=True)
