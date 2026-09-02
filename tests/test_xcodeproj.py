import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).parents[1]
IOS = ROOT / "apps" / "ios"
ATLAS = IOS / "Atlas"
ATLAS_TESTS = IOS / "AtlasTests"
ATLAS_DOWNLOADER = IOS / "AtlasDownloader"
PROJECT = IOS / "Atlas.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
WORKSPACE = PROJECT / "project.xcworkspace" / "contents.xcworkspacedata"
SIBLING_WORKSPACE = IOS / "Atlas.xcworkspace" / "contents.xcworkspacedata"
SCHEME = PROJECT / "xcshareddata" / "xcschemes" / "Atlas.xcscheme"

ID_RE = re.compile(r"\b([A-F0-9]{24})\b")
DEFINED_RE = re.compile(
    r"^[\t ]*([A-F0-9]{24}) (?:/\*[^*]*\*/ )?= \{",
    re.MULTILINE,
)


def defined_ids(text: str) -> set[str]:
    return set(DEFINED_RE.findall(text))


def native_target(text: str, name: str) -> tuple[str, str]:
    match = re.search(
        rf"^\s*([A-F0-9]{{24}}) /\* {re.escape(name)} \*/ = \{{\s*"
        rf"isa = PBXNativeTarget;.*?\n\s*\}};",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"{name} native target missing")
    return match.group(1), match.group(0)


def build_configuration(text: str, name: str, required: str) -> str:
    matches = re.findall(
        rf"^\s*[A-F0-9]{{24}} /\* {name} \*/ = \{{\s*"
        rf"isa = XCBuildConfiguration;.*?\n\s*name = {name};\s*\n\s*\}};",
        text,
        re.MULTILINE | re.DOTALL,
    )
    match = next((body for body in matches if required in body), None)
    if match is None:
        raise AssertionError(f"{name} build configuration with {required!r} missing")
    return match


class AtlasXcodeprojTests(unittest.TestCase):
    def setUp(self) -> None:
        self.pbx = PBXPROJ.read_text(encoding="utf-8")

    def test_workspace_self_ref_exists(self) -> None:
        self.assertTrue(WORKSPACE.is_file())
        text = WORKSPACE.read_text(encoding="utf-8")
        self.assertIn('location = "self:"', text)

    def test_sibling_workspace_points_at_xcodeproj(self) -> None:
        self.assertTrue(
            SIBLING_WORKSPACE.is_file(),
            "Finder should also show Atlas.xcworkspace as an openable package.",
        )
        text = SIBLING_WORKSPACE.read_text(encoding="utf-8")
        self.assertIn('location = "container:Atlas.xcodeproj"', text)

    def test_pbxproj_is_classic_xcode14_format(self) -> None:
        self.assertTrue(self.pbx.startswith("// !$*UTF8*$!"))
        self.assertIn("objectVersion = 56;", self.pbx)
        self.assertIn('compatibilityVersion = "Xcode 14.0";', self.pbx)
        self.assertNotIn("PBXFileSystemSynchronizedRootGroup", self.pbx)
        self.assertNotIn("preferredProjectObjectVersion", self.pbx)
        self.assertNotIn("fileSystemSynchronizedGroups", self.pbx)

    def test_application_target_has_required_build_phases(self) -> None:
        for phase in (
            "PBXSourcesBuildPhase",
            "PBXFrameworksBuildPhase",
            "PBXResourcesBuildPhase",
        ):
            self.assertIn(f"isa = {phase};", self.pbx)

        _, body = native_target(self.pbx, "Atlas")
        self.assertIn('productType = "com.apple.product-type.application";', body)
        self.assertIn("/* Sources */", body)
        self.assertIn("/* Frameworks */", body)
        self.assertIn("/* Resources */", body)
        self.assertIn("/* Embed ExtensionKit Extensions */", body)
        self.assertIn("/* PBXTargetDependency */", body)

    def test_every_swift_file_is_in_sources(self) -> None:
        swift_files = sorted(
            path.name
            for root in (ATLAS, ATLAS_TESTS, ATLAS_DOWNLOADER)
            for path in root.rglob("*.swift")
        )
        self.assertGreaterEqual(len(swift_files), 10)
        for name in swift_files:
            self.assertIn(
                f"/* {name} in Sources */",
                self.pbx,
                f"{name} must be an explicit Sources build file",
            )

    def test_resources_include_preview_pair_not_plists_or_entitlements(self) -> None:
        self.assertIn("/* Assets.xcassets in Resources */", self.pbx)
        self.assertIn("/* nms-reference.sqlite in Resources */", self.pbx)
        self.assertIn("/* pack-manifest.json in Resources */", self.pbx)
        self.assertIn("/* PrivacyInfo.xcprivacy in Resources */", self.pbx)
        self.assertNotIn("/* Info.plist in Resources */", self.pbx)
        self.assertNotIn(".entitlements in Resources */", self.pbx)
        self.assertIn("path = Info.plist;", self.pbx)
        self.assertIn("CODE_SIGN_ENTITLEMENTS = Atlas/Atlas.entitlements;", self.pbx)

    def test_release_excludes_both_preview_pack_files(self) -> None:
        debug = build_configuration(
            self.pbx, "Debug", "PRODUCT_BUNDLE_IDENTIFIER = ai.atlas.nms;"
        )
        release = build_configuration(
            self.pbx, "Release", "PRODUCT_BUNDLE_IDENTIFIER = ai.atlas.nms;"
        )
        self.assertNotIn("EXCLUDED_SOURCE_FILE_NAMES", debug)
        self.assertIn("EXCLUDED_SOURCE_FILE_NAMES = (", release)
        self.assertIn('"nms-reference.sqlite",', release)
        self.assertIn('"pack-manifest.json",', release)

    def test_test_target_is_explicit_and_hosted_by_atlas(self) -> None:
        atlas_id, _ = native_target(self.pbx, "Atlas")
        _, tests = native_target(self.pbx, "AtlasTests")
        self.assertIn('productType = "com.apple.product-type.bundle.unit-test";', tests)
        self.assertIn("/* AtlasTests.xctest */", tests)
        self.assertIn("/* PBXTargetDependency */", tests)
        self.assertIn("/* AtlasTests.swift in Sources */", self.pbx)
        self.assertIn(f"TestTargetID = {atlas_id};", self.pbx)
        self.assertIn("BUNDLE_LOADER = \"$(TEST_HOST)\";", self.pbx)
        self.assertIn(
            "TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/Atlas.app/"
            "$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Atlas\";",
            self.pbx,
        )

    def test_downloader_target_is_embedded_and_configured(self) -> None:
        downloader_id, downloader = native_target(self.pbx, "AtlasDownloader")
        self.assertIn(
            'productType = "com.apple.product-type.extensionkit-extension";',
            downloader,
        )
        self.assertIn("/* AtlasDownloader.appex */", downloader)
        self.assertIn("/* DownloaderExtension.swift in Sources */", self.pbx)
        self.assertIn("dstPath = Extensions;", self.pbx)
        self.assertIn("dstSubfolderSpec = 1;", self.pbx)
        self.assertIn(
            "/* AtlasDownloader.appex in Embed ExtensionKit Extensions */",
            self.pbx,
        )
        self.assertRegex(
            self.pbx,
            rf"target = {downloader_id} /\* AtlasDownloader \*/;",
        )
        self.assertIn("APPLICATION_EXTENSION_API_ONLY = YES;", self.pbx)
        self.assertIn(
            "CODE_SIGN_ENTITLEMENTS = "
            "AtlasDownloader/AtlasDownloader.entitlements;",
            self.pbx,
        )
        self.assertIn("INFOPLIST_FILE = AtlasDownloader/Info.plist;", self.pbx)
        self.assertIn("SKIP_INSTALL = YES;", self.pbx)

    def test_object_ids_are_not_near_zero(self) -> None:
        defined = defined_ids(self.pbx)
        self.assertGreaterEqual(len(defined), 20)
        for oid in defined:
            self.assertGreaterEqual(
                len(set(oid)),
                8,
                f"{oid} looks like a placeholder ID; Xcode 27 may treat "
                "low-entropy IDs as null and fail project open with EINVAL",
            )

    def test_every_referenced_id_is_defined(self) -> None:
        defined = defined_ids(self.pbx)
        referenced = set(ID_RE.findall(self.pbx))
        missing = referenced - defined
        self.assertEqual(missing, set(), f"dangling pbxproj IDs: {missing}")

    def test_scheme_references_all_targets_with_expected_actions(self) -> None:
        target_ids = {
            name: native_target(self.pbx, name)[0]
            for name in ("Atlas", "AtlasTests", "AtlasDownloader")
        }
        root = ET.parse(SCHEME).getroot()
        references = root.findall(".//BuildableReference")
        self.assertGreaterEqual(len(references), 7)
        for reference in references:
            name = reference.attrib["BlueprintName"]
            self.assertIn(name, target_ids)
            self.assertEqual(reference.attrib["BlueprintIdentifier"], target_ids[name])

        entries = {
            entry.find("BuildableReference").attrib["BlueprintName"]: entry
            for entry in root.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
        }
        self.assertEqual(set(entries), {"Atlas", "AtlasTests", "AtlasDownloader"})
        for name in ("Atlas", "AtlasDownloader"):
            for action in (
                "buildForTesting",
                "buildForRunning",
                "buildForProfiling",
                "buildForArchiving",
                "buildForAnalyzing",
            ):
                self.assertEqual(entries[name].attrib[action], "YES")
        self.assertEqual(entries["AtlasTests"].attrib["buildForTesting"], "YES")
        for action in (
            "buildForRunning",
            "buildForProfiling",
            "buildForArchiving",
            "buildForAnalyzing",
        ):
            self.assertEqual(entries["AtlasTests"].attrib[action], "NO")

        macro = root.find("./TestAction/MacroExpansion/BuildableReference")
        self.assertIsNotNone(macro)
        self.assertEqual(macro.attrib["BlueprintName"], "Atlas")
        testable = root.find("./TestAction/Testables/TestableReference")
        self.assertIsNotNone(testable)
        self.assertEqual(testable.attrib["skipped"], "NO")
        self.assertEqual(testable.attrib["parallelizable"], "NO")
        self.assertEqual(
            testable.find("BuildableReference").attrib["BlueprintName"],
            "AtlasTests",
        )


if __name__ == "__main__":
    unittest.main()
