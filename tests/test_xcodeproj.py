import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
IOS = ROOT / "apps" / "ios"
ATLAS = IOS / "Atlas"
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

        target = re.search(
            r"/\* Atlas \*/ = \{\s*isa = PBXNativeTarget;.*?productType = "
            r'"com\.apple\.product-type\.application";\s*\};',
            self.pbx,
            re.DOTALL,
        )
        self.assertIsNotNone(target, "Atlas application target missing")
        body = target.group(0)
        self.assertIn("/* Sources */", body)
        self.assertIn("/* Frameworks */", body)
        self.assertIn("/* Resources */", body)

    def test_every_swift_file_is_in_sources(self) -> None:
        swift_files = sorted(path.name for path in ATLAS.rglob("*.swift"))
        self.assertGreaterEqual(len(swift_files), 10)
        for name in swift_files:
            self.assertIn(
                f"/* {name} in Sources */",
                self.pbx,
                f"{name} must be an explicit Sources build file",
            )

    def test_resources_include_assets_and_sqlite_not_info_plist(self) -> None:
        self.assertIn("/* Assets.xcassets in Resources */", self.pbx)
        self.assertIn("/* nms-reference.sqlite in Resources */", self.pbx)
        self.assertIn("/* PrivacyInfo.xcprivacy in Resources */", self.pbx)
        self.assertNotIn("/* Info.plist in Resources */", self.pbx)
        self.assertNotIn("/* Atlas.entitlements in Resources */", self.pbx)
        self.assertIn("path = Info.plist;", self.pbx)
        self.assertIn("CODE_SIGN_ENTITLEMENTS = Atlas/Atlas.entitlements;", self.pbx)

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

    def test_scheme_points_at_atlas_target(self) -> None:
        scheme = SCHEME.read_text(encoding="utf-8")
        match = re.search(
            r'BlueprintIdentifier = "([A-F0-9]{24})"', scheme
        )
        self.assertIsNotNone(match)
        blueprint = match.group(1)
        self.assertIn(f"{blueprint} /* Atlas */", self.pbx)
        self.assertIn('productType = "com.apple.product-type.application";', self.pbx)


if __name__ == "__main__":
    unittest.main()
