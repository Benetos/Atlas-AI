import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
PROJECT = ROOT / "apps" / "ios" / "Atlas.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
WORKSPACE = PROJECT / "project.xcworkspace" / "contents.xcworkspacedata"
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
        self.assertTrue(
            WORKSPACE.is_file(),
            "Xcode opens .xcodeproj through project.xcworkspace/"
            "contents.xcworkspacedata; that file was missing and Xcode 27 "
            "fails with NSPOSIXErrorDomain 22 (EINVAL).",
        )
        text = WORKSPACE.read_text(encoding="utf-8")
        self.assertIn('location = "self:"', text)
        self.assertIn("<Workspace", text)

    def test_pbxproj_is_openstep_plist(self) -> None:
        self.assertTrue(self.pbx.startswith("// !$*UTF8*$!"))
        self.assertIn("archiveVersion = 1;", self.pbx)
        self.assertIn("rootObject = ", self.pbx)
        self.assertNotIn("\x00", self.pbx)

    def test_application_target_has_required_build_phases(self) -> None:
        for phase in (
            "PBXSourcesBuildPhase",
            "PBXFrameworksBuildPhase",
            "PBXResourcesBuildPhase",
        ):
            self.assertIn(
                f"isa = {phase};",
                self.pbx,
                f"Hand-written project omitted {phase}; Xcode-generated "
                "synchronized-folder apps still declare empty Sources/"
                "Frameworks/Resources phases.",
            )

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
        self.assertIn("packageProductDependencies = (", body)
        self.assertIn("fileSystemSynchronizedGroups = (", body)

    def test_info_plist_is_a_membership_exception(self) -> None:
        self.assertIn(
            "isa = PBXFileSystemSynchronizedBuildFileExceptionSet;",
            self.pbx,
        )
        self.assertRegex(
            self.pbx,
            r"membershipExceptions = \([^)]*Info\.plist,",
        )

    def test_every_referenced_id_is_defined(self) -> None:
        defined = defined_ids(self.pbx)
        self.assertGreaterEqual(len(defined), 10)
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
