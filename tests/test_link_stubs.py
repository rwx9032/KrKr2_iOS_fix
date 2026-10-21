import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("link_stubs", Path(__file__).parents[1] / "tools/make_link_stubs.py")
link_stubs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(link_stubs)


class LinkStubTests(unittest.TestCase):
    def test_real_runtime_msgsend_import(self):
        self.assertEqual(link_stubs.library_for("_objc_msgSend"), "objc")

    def test_selector_specific_linker_symbol_must_not_be_faked(self):
        with self.assertRaisesRegex(ValueError, "linker-generated stub"):
            link_stubs.library_for("_objc_msgSend$mainBundle")

    def test_runtime_classes_and_unwinder(self):
        self.assertEqual(link_stubs.library_for("_OBJC_CLASS_$_UIAlertController"), "UIKit")
        self.assertEqual(link_stubs.library_for("_OBJC_CLASS_$_NSBundle"), "Foundation")
        self.assertEqual(link_stubs.library_for("__Unwind_Resume"), "System")

    def test_unknown_runtime_import_rejected(self):
        with self.assertRaises(ValueError):
            link_stubs.library_for("_not_a_system_export")
