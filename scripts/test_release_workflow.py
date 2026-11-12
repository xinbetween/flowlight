#!/usr/bin/env python3
"""Static fail-closed contract for the prepare/publish privilege split."""

import pathlib
import re
import unittest

WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/release.yml"
CI_WORKFLOW = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
FORBIDDEN_PUBLICATION = (
    "APP_CERTIFICATE_P12", "INSTALLER_CERTIFICATE_P12", "CERTIFICATE_PASSWORD",
    "APP_PROVISIONING_PROFILE", "EXT_PROVISIONING_PROFILE", "APP_PROFILE", "EXT_PROFILE",
    "NOTARY_", "TEAM_ID", "DMG_SIGN_IDENTITY", "INSTALLER_IDENTITY",
    "security ", "xcodebuild", "xcrun ", "build-signed.sh", "build-dmg.sh", "build-pkg.sh",
    "notarize.sh", "codesign", "productbuild", "productsign", "notarytool",
)


def job_block(text, name, next_name=None):
    start = text.index(f"  {name}:\n")
    end = text.index(f"  {next_name}:\n", start) if next_name else len(text)
    return text[start:end]


def permissions(block):
    lines = block.splitlines()
    start = lines.index("    permissions:") + 1
    result = {}
    for line in lines[start:]:
        match = re.fullmatch(r"      ([a-z-]+): (read|write|none)", line)
        if not match:
            break
        result[match.group(1)] = match.group(2)
    return result


def run_scripts(block):
    lines = block.splitlines()
    scripts = []
    index = 0
    while index < len(lines):
        if lines[index] == "        run: |":
            index += 1
            body = []
            while index < len(lines) and (not lines[index] or lines[index].startswith("          ")):
                body.append(lines[index][10:] if lines[index].startswith("          ") else "")
                index += 1
            scripts.append("\n".join(body))
        else:
            index += 1
    return scripts


def forbidden_publication_values(block):
    return [value for value in FORBIDDEN_PUBLICATION if value in block]


class ReleaseWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text()
        cls.ci_workflow = CI_WORKFLOW.read_text()
        cls.prepare = job_block(cls.workflow, "prepare", "publish")
        cls.publish = job_block(cls.workflow, "publish", "homebrew")
        cls.homebrew = job_block(cls.workflow, "homebrew")
        cls.merge_compatibility = job_block(cls.ci_workflow, "merge-compatibility", "gate")

    def test_manual_publication_requires_preparation_run(self):
        self.assertRegex(self.workflow, r"(?m)^      prepare_run_id:\n")
        self.assertIn("github.event_name == 'push'", self.prepare)
        self.assertIn("github.event_name == 'workflow_dispatch'", self.publish)

    def test_preparation_cannot_publish(self):
        self.assertEqual(permissions(self.prepare), {
            "contents": "read", "checks": "read", "issues": "read", "pull-requests": "read",
            "actions": "read", "id-token": "write", "attestations": "write",
        })
        self.assertNotIn("gh release", self.prepare)
        self.assertIn("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02", self.prepare)
        self.assertIn("if-no-files-found: error", self.prepare)
        self.assertIn("retention-days: 90", self.prepare)

    def test_preparation_stages_only_release_files(self):
        self.assertIn('BUNDLE="$RUNNER_TEMP/prepared-release"', self.prepare)
        self.assertIn('mkdir "$BUNDLE"', self.prepare)
        self.assertIn(
            'cp build/Flowlight.dmg "build/Flowlight-$VERSION.pkg" build/SHA256SUMS.txt "$BUNDLE/"',
            self.prepare,
        )
        self.assertEqual(self.prepare.count('--bundle "$BUNDLE"'), 2)
        self.assertNotIn("--bundle build", self.prepare)
        for name in (
            "Flowlight.dmg", "Flowlight-${{ steps.version.outputs.version }}.pkg",
            "SHA256SUMS.txt", "RELEASE-NOTES.md", "RELEASE-MANIFEST.json",
        ):
            self.assertIn(f"${{{{ runner.temp }}}}/prepared-release/{name}", self.prepare)

    def test_preparation_requires_authenticated_review_comments(self):
        self.assertIn("RELEASE_REVIEWERS", self.prepare)
        self.assertIn('issues/$pull_number/comments?per_page=100', self.prepare)
        self.assertNotIn('issues/comments?per_page=100', self.prepare)
        self.assertIn('for attempt in 1 2 3 4 5 6', self.prepare)
        self.assertIn('select(.head.sha == $sha and .base.ref == "main")', self.prepare)
        self.assertIn('--comments "$COMMENTS"', self.prepare)
        self.assertIn('--reviewers "$RELEASE_REVIEWERS"', self.prepare)
        self.assertNotIn("pull request whose body", self.prepare)

    def test_review_lookup_contract_rejects_repository_wide_comment_scan(self):
        tampered = self.prepare.replace(
            'issues/$pull_number/comments?per_page=100',
            'issues/comments?per_page=100',
        )
        self.assertNotIn('issues/$pull_number/comments?per_page=100', tampered)
        self.assertIn('issues/comments?per_page=100', tampered)

    def test_merge_compatibility_uses_pull_request_default_merge_ref(self):
        self.assertIn("actions/checkout@", self.merge_compatibility)
        self.assertNotIn("refs/pull/", self.merge_compatibility)
        self.assertNotRegex(self.merge_compatibility, r"(?m)^          ref:")

    def test_untrusted_checkout_detector_rejects_deliberate_ref_fixture(self):
        unsafe = self.merge_compatibility.replace(
            "      - uses: actions/checkout@",
            "      - uses: actions/checkout@",
        ) + "\n        with:\n          ref: refs/pull/${{ github.event.number }}/merge\n"
        self.assertIn("refs/pull/", unsafe)
        self.assertRegex(unsafe, r"(?m)^          ref:")

    def test_publication_has_only_distribution_permissions(self):
        self.assertEqual(permissions(self.publish), {
            "actions": "read", "attestations": "read", "contents": "write",
        })
        self.assertNotRegex(self.publish, r"(?m)^    environment: release$")
        self.assertIn("persist-credentials: false", self.publish)

    def test_shell_scripts_never_interpolate_actions_expressions(self):
        declarations = re.findall(r"(?m)^\s+run:", self.workflow)
        self.assertEqual(len(run_scripts(self.workflow)), len(declarations), "every shell step must use a literal run: | block")
        for script in run_scripts(self.workflow):
            self.assertNotIn("${{", script)
        self.assertIn("github.triggering_actor", self.prepare)
        self.assertIn("github.triggering_actor", self.publish)
        self.assertNotIn("TAP_TOKEN", self.publish)
        self.assertNotIn("x-access-token", self.publish)
        self.assertIn("TAP_TOKEN: ${{ secrets.TAP_TOKEN }}", self.homebrew)
        self.assertIn('export GH_TOKEN="$TAP_TOKEN"', self.homebrew)

    def test_expression_detector_rejects_deliberate_input_injection_fixture(self):
        unsafe = "        run: |\n          run_id=\"${{ inputs.prepare_run_id }}\"\n"
        scripts = run_scripts(unsafe)
        self.assertEqual(len(scripts), 1)
        self.assertIn("${{", scripts[0])

    def test_publication_cannot_build_sign_or_notarize(self):
        self.assertEqual(forbidden_publication_values(self.publish), [])

    def test_forbidden_command_detector_rejects_deliberate_tamper(self):
        self.assertEqual(forbidden_publication_values(self.publish + "\nxcodebuild archive\n"), ["xcodebuild"])

    def test_archive_provenance_and_draft_bytes_are_ordered_before_publication(self):
        digest = self.publish.index('ACTUAL="sha256:$(sha256sum')
        extract = self.publish.index("release_artifact.py extract-archive")
        bundle = self.publish.index("verify-bundle")
        attest = self.publish.index("gh attestation verify")
        create = self.publish.index("gh release create")
        download = self.publish.index("gh release download")
        compare = self.publish.index('cmp "$PREPARED/Flowlight.dmg"')
        publish = self.publish.index('gh release edit "$TAG" --draft=false')
        self.assertLess(digest, extract)
        self.assertLess(extract, bundle)
        self.assertLess(bundle, attest)
        self.assertLess(attest, create)
        self.assertLess(create, download)
        self.assertLess(download, compare)
        self.assertLess(compare, publish)
        for value in (
            'cmp "$PREPARED/Flowlight-$VERSION.pkg"',
            'cmp "$PREPARED/SHA256SUMS.txt"',
            'cmp "$PREPARED/RELEASE-MANIFEST.json"',
            "release body differs from the prepared release notes",
        ):
            self.assertIn(value, self.publish)

    def test_publication_is_resumable_without_mutating_public_assets(self):
        self.assertIn("Resuming the existing draft", self.publish)
        self.assertIn("public release already exists", self.publish)
        self.assertIn("it will be verified without mutation", self.publish)
        self.assertIn("gh release upload", self.publish)
        self.assertIn("--clobber", self.publish)

    def test_homebrew_runs_only_after_publication_with_the_existing_environment_secret(self):
        self.assertIn("needs: publish", self.homebrew)
        self.assertRegex(self.homebrew, r"(?m)^    environment: release$")
        self.assertEqual(permissions(self.homebrew), {"contents": "read"})
        self.assertIn('gh release view "$EVENT_TAG" --json isDraft', self.homebrew)
        self.assertIn('gh release download "$EVENT_TAG"', self.homebrew)
        self.assertIn('ACTUAL=$(sha256sum "$PUBLIC/Flowlight.dmg"', self.homebrew)
        self.assertIn("REQUIRE_LOCAL_DMG=1", self.homebrew)
        self.assertNotRegex(self.homebrew, r"update-cask\.sh[^\n]*https?://")
        self.assertEqual(forbidden_publication_values(self.homebrew), [])


if __name__ == "__main__":
    unittest.main()
