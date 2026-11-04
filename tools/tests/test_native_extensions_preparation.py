"""Source tests for the maintained plugin preparation (not executed yet)."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "prepare_native_extensions.py"
SPEC = importlib.util.spec_from_file_location("native_extensions_preparation", SCRIPT)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)

ORIGINAL = '''use windows::{
        System::{
        },
            FD_PROGRESSUI, FILEDESCRIPTORW,
};
impl DataObject {
    fn file_descriptor_for_item(old: &str) { old(); }
    fn data_for_file_group_descritor(&self) { old(); }
    fn create_virtual_stream_session() {}
}
'''
DROP_ORIGINAL = '''impl PlatformDropContext {
    fn assign_weak_self(&self, weak_self: Weak<Self>) {
        self.weak_self.set(weak_self.clone());
        unsafe { RevokeDragDrop(self.view); RegisterDragDrop(self.view, target); }
    }
}
impl Drop for PlatformDropContext {
    fn drop(&mut self) {
        unsafe {
            let hook = *self.hook;
            UnhookWinEvent(hook);
        }
    }
}
'''


def archive(extra=()):
    result = io.BytesIO()
    files = {"LICENSE": b"test-only synthetic license fixture", "pubspec.yaml": b"name: super_native_extensions\n", "rust/src/win32/data_object.rs": ORIGINAL.encode(), "rust/src/win32/drop.rs": DROP_ORIGINAL.encode()}
    with tarfile.open(fileobj=result, mode="w:gz") as tar:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))
        for member in extra:
            tar.addfile(member)
    return result.getvalue()


class PreparationTests(unittest.TestCase):
    def test_checksum_refuses_unknown_code_before_creating_a_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "prepared"
            with self.assertRaises(ValueError):
                module.prepare(b"not the pinned upstream archive", "patch", target)
            self.assertFalse(target.exists())

    def test_idempotence_and_local_edit_preservation(self):
        payload = archive()
        replacement = (SCRIPT.parent / "native_extensions_descriptor.rs").read_text()
        with tempfile.TemporaryDirectory() as directory, patch.object(module, "ARCHIVE_SHA256", hashlib.sha256(payload).hexdigest()):
            target = Path(directory) / "prepared"
            module.prepare(payload, replacement, target)
            self.assertEqual(module.prepare(payload, replacement, target), target)
            source = target / "rust/src/win32/data_object.rs"
            self.assertIn("FILE_ATTRIBUTE_DIRECTORY", source.read_text())
            self.assertNotIn("old();", source.read_text())
            source.write_text("user modification")
            with self.assertRaises(ValueError):
                module.prepare(payload, replacement, target)
            self.assertEqual(source.read_text(), "user modification")

    def test_unsafe_tar_entries_and_symlink_destination_are_refused(self):
        for name, kind in [("../escaped", tarfile.REGTYPE), ("link", tarfile.SYMTYPE), ("hard", tarfile.LNKTYPE)]:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.linkname = "/outside"
            payload = archive([member])
            with patch.object(module, "ARCHIVE_SHA256", hashlib.sha256(payload).hexdigest()):
                with self.assertRaises(ValueError):
                    module.archive_files(payload)
        payload = archive()
        with tempfile.TemporaryDirectory() as directory, patch.object(module, "ARCHIVE_SHA256", hashlib.sha256(payload).hexdigest()):
            target = Path(directory) / "prepared"
            target.symlink_to(Path(directory), target_is_directory=True)
            with self.assertRaises(ValueError):
                module.prepare(payload, (SCRIPT.parent / "native_extensions_descriptor.rs").read_text(), target)
            self.assertTrue(target.is_symlink())

    def test_patch_refuses_changed_or_duplicate_anchors(self):
        replacement = (SCRIPT.parent / "native_extensions_descriptor.rs").read_text()
        for original in [ORIGINAL.replace("fn file_descriptor_for_item", "fn changed"), ORIGINAL + ORIGINAL]:
            with self.assertRaises(ValueError):
                module.patch_source(original, replacement)

    def test_owned_hwnd_guard_precedes_any_revoke_and_has_matching_destructor(self):
        result = module.patch_drop_source(DROP_ORIGINAL)
        self.assertLess(result.index('GetPropW('), result.index('RevokeDragDrop('))
        self.assertLess(result.index('self.hook.set(HWINEVENTHOOK(0))'), result.index('RegisterDragDrop('))
        self.assertLess(result.index('if hook.0 == 0'), result.index('UnhookWinEvent('))
        self.assertIn('HSPTerm.ExplorerDropOwner.v1', result)
        with self.assertRaises(ValueError):
            module.patch_drop_source(DROP_ORIGINAL + DROP_ORIGINAL)


if __name__ == "__main__":
    unittest.main()
