"""Queued source-generator regressions; run in the final unified test batch."""
import unittest
from bridge_error_boundaries import functions, wrap, production_tokens


class BoundarySourceTests(unittest.TestCase):
    def test_raw_strings_chars_nested_comments_and_fake_functions_are_not_code(self):
        source = '''
pub async fn actual() -> Result<String> {
    let payload = r###"} pub async fn fake() -> Result<()> { }"###;
    let escaped = "\\\"}";
    let braces = ('}', '{');
    /* { /* } */ pub fn hidden() -> Result<()> { } */
    Ok(payload.into())
}
impl Item { pub fn method() -> Result<()> { Ok(()) } }
#[cfg(test)] mod tests { pub fn fixture() -> Result<()> { Ok(()) } }
'''
        self.assertEqual([f[0] for f in functions(source)], ['actual'])
        updated, count = wrap(source)
        self.assertEqual(count, 1)
        self.assertIn('crate::public_errors::finish(outcome)', updated)
        self.assertEqual(wrap(updated), (updated, 0))

        sync = '''pub fn old_sync() -> Result<()> {
/* HSPTERM_PUBLIC_ERROR_BOUNDARY */
let outcome: Result<_> = (move || retain(r#"}"#))();
crate::public_errors::finish(outcome)
}'''
        migrated, count = wrap(sync)
        self.assertEqual(count, 1)
        self.assertIn('guard_sync(move || {retain(r#"}"#)})', migrated)
        self.assertEqual(wrap(migrated), (migrated, 0))

    def test_sync_and_async_results_are_wrapped_but_plain_values_and_crate_helpers_are_not(self):
        source = 'pub fn sync() -> Result<u32> { return Ok(1); } pub async fn asynchronous() -> Result<()> { Ok(()) } pub fn plain() -> bool { true } pub(crate) fn internal() -> Result<()> { Ok(()) }'
        updated, count = wrap(source)
        self.assertEqual(count, 2)
        self.assertIn('guard_sync(move || { return Ok(1); })', updated)
        self.assertIn('guard(async move { Ok(()) }).await', updated)
        self.assertIn('pub(crate) fn internal() -> Result<()> { Ok(()) }', updated)

    def test_test_only_private_markers_do_not_enter_the_public_literal_allowlist(self):
        source = 'const BEFORE: &str = "公开摘要"; #[cfg(test)] mod tests { const SECRET: &str = "测试秘密"; } const AFTER: &str = "后续生产摘要";'
        strings = [t[1] for t in production_tokens(source) if t[0] == 'string']
        self.assertEqual(strings, ['"公开摘要"', '"后续生产摘要"'])

    def test_legacy_result_boundary_upgrades_without_changing_owned_business_code(self):
        source = '''pub async fn old() -> Result<()> {
/* HSPTERM_PUBLIC_ERROR_BOUNDARY */
let outcome: Result<_> = (async move { let quoted = r#"}"#; retain(quoted)?; Ok(()) }).await;
crate::public_errors::finish(outcome)
}'''
        updated, count = wrap(source)
        self.assertEqual(count, 1)
        self.assertIn('guard(async move { let quoted = r#"}"#; retain(quoted)?; Ok(()) }).await', updated)
        self.assertEqual(wrap(updated), (updated, 0))


if __name__ == '__main__':
    unittest.main()
