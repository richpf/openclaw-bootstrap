"""
Tests for provision_lightsail.py

Run with:
    cd provisioner && pytest tests/ -v

No live AWS calls — boto3 is fully mocked.
"""

from __future__ import annotations

import json
import os
import sys
import textwrap
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import yaml

# Make the provisioner importable without installing
sys.path.insert(0, str(Path(__file__).parent.parent))

from provision_lightsail import (
    ProvisionState,
    LightsailProvisioner,
    load_fork_yaml,
    validate_fork_yaml,
    resolve_config,
    render_cloud_init,
    get_nested,
    TAILSCALE_AUTH_KEY_PREFIX,
    FIREWALL_INITIAL,
    FIREWALL_FINAL,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

FIXTURES_DIR = Path(__file__).parent / "fixtures"
SAMPLE_FORK_YAML = FIXTURES_DIR / "fork.sample.yaml"
CLOUD_INIT_EXPECTED = FIXTURES_DIR / "cloud_init.expected.yaml"


@pytest.fixture
def sample_yaml_data():
    with open(SAMPLE_FORK_YAML) as f:
        return yaml.safe_load(f)


@pytest.fixture
def sample_cfg(sample_yaml_data):
    return resolve_config(sample_yaml_data)


@pytest.fixture
def fake_ts_key():
    return f"{TAILSCALE_AUTH_KEY_PREFIX}FAKE1234567890abcdefghij"


@pytest.fixture
def fake_operator_pubkey():
    return "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTesting operator@testhost"


@pytest.fixture
def provisioner_dry(sample_cfg, fake_ts_key):
    """LightsailProvisioner in dry-run mode (no boto3 needed)."""
    return LightsailProvisioner(
        cfg=sample_cfg,
        aws_profile="default",
        dry_run=True,
        skip_dns=True,
    )


# ---------------------------------------------------------------------------
# 1. fork.yaml validation
# ---------------------------------------------------------------------------

class TestForkYamlValidation:
    def test_valid_sample_passes(self, sample_yaml_data):
        errors = validate_fork_yaml(sample_yaml_data)
        assert errors == [], f"Expected no errors, got: {errors}"

    def test_missing_required_field_domain(self, sample_yaml_data):
        del sample_yaml_data["infra"]["domain"]
        errors = validate_fork_yaml(sample_yaml_data)
        assert any("infra.domain" in e for e in errors)

    def test_missing_required_field_certbot_email(self, sample_yaml_data):
        sample_yaml_data["infra"]["certbot_email"] = ""
        errors = validate_fork_yaml(sample_yaml_data)
        assert any("infra.certbot_email" in e for e in errors)

    def test_missing_git_section(self, sample_yaml_data):
        del sample_yaml_data["git"]
        errors = validate_fork_yaml(sample_yaml_data)
        assert any("git." in e for e in errors)

    def test_missing_tailscale_key_env(self, sample_yaml_data):
        del sample_yaml_data["infra"]["tailscale_auth_key_env"]
        errors = validate_fork_yaml(sample_yaml_data)
        assert any("tailscale_auth_key_env" in e for e in errors)

    def test_optional_fields_do_not_cause_errors(self, sample_yaml_data):
        # These are optional — removing them should not fail validation
        sample_yaml_data["infra"].pop("ssh_pubkey_path", None)
        sample_yaml_data["infra"].pop("deployer_pubkey_path", None)
        errors = validate_fork_yaml(sample_yaml_data)
        assert errors == []

    def test_empty_yaml_fails(self):
        errors = validate_fork_yaml({})
        assert len(errors) >= 5  # all required fields missing

    def test_not_a_dict_raises(self):
        with pytest.raises(ValueError, match="dict"):
            validate_fork_yaml("not a dict")  # type: ignore


class TestGetNested:
    def test_simple_path(self):
        assert get_nested({"a": {"b": 42}}, "a.b") == 42

    def test_missing_path_returns_default(self):
        assert get_nested({}, "a.b.c", "fallback") == "fallback"

    def test_none_default(self):
        assert get_nested({"x": {}}, "x.missing") is None


class TestResolveConfig:
    def test_slug_from_explicit(self, sample_yaml_data):
        cfg = resolve_config(sample_yaml_data)
        assert cfg["slug"] == "testop"

    def test_slug_derived_from_github_handle(self, sample_yaml_data):
        del sample_yaml_data["infra"]["slug"]
        cfg = resolve_config(sample_yaml_data)
        assert cfg["slug"] == "testop"  # from github_handle = "testop"

    def test_instance_name_derived(self, sample_yaml_data):
        cfg = resolve_config(sample_yaml_data)
        assert cfg["instance_name"] == "openclaw-testop"

    def test_static_ip_name_derived(self, sample_yaml_data):
        cfg = resolve_config(sample_yaml_data)
        assert cfg["static_ip_name"] == "openclaw-testop-ip"

    def test_domain_propagated(self, sample_yaml_data):
        cfg = resolve_config(sample_yaml_data)
        assert cfg["domain"] == "example2.com"


# ---------------------------------------------------------------------------
# 2. cloud-init Jinja rendering
# ---------------------------------------------------------------------------

class TestCloudInitRendering:
    def test_renders_without_error(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert isinstance(result, str)
        assert len(result) > 100

    def test_slug_substituted(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "testop" in result

    def test_domain_substituted(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "example2.com" in result

    def test_certbot_email_substituted(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "admin@example2.com" in result

    def test_operator_pubkey_substituted(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert fake_operator_pubkey in result

    def test_ssh_safeguards_present(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        # All three safeguards must be present
        assert "systemctl mask ssh.socket" in result, "Missing: mask ssh.socket"
        assert "passwd -l ubuntu" in result, "Missing: passwd -l ubuntu (safe lockout)"
        assert "ssh-watchdog" in result, "Missing: SSH watchdog cron"

    def test_nologin_never_in_cloud_init(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "nologin ubuntu" not in result, "Found dangerous nologin ubuntu directive"

    def test_port_2222_configured(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "Port 2222" in result

    def test_tailscale_placeholder_in_dry_run(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        # In dry-run render, tailscale key is a placeholder
        assert "{{ TAILSCALE_AUTH_KEY }}" in result or "TAILSCALE_AUTH_KEY" in result

    def test_ufw_rules_present(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "100.64.0.0/10" in result  # Tailscale CGNAT range
        assert "443/tcp" in result

    def test_restic_no_repo_init(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "restic init" not in result, "restic repo init must NOT run without B2 creds"

    def test_sentinel_file_present(self, sample_cfg, fake_operator_pubkey):
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        assert "lightsail-hardening-complete" in result

    def test_matches_expected_snapshot(self, sample_cfg, fake_operator_pubkey):
        """Snapshot test: rendered output must match committed fixture."""
        result = render_cloud_init(sample_cfg, fake_operator_pubkey)
        if not CLOUD_INIT_EXPECTED.exists():
            # First run: write the fixture
            CLOUD_INIT_EXPECTED.write_text(result)
            pytest.skip("Fixture cloud_init.expected.yaml created on first run — re-run to validate")

        expected = CLOUD_INIT_EXPECTED.read_text()
        if result != expected:
            # Show a diff for easier debugging
            import difflib
            diff = "\n".join(difflib.unified_diff(
                expected.splitlines(), result.splitlines(),
                fromfile="expected", tofile="actual", lineterm=""
            ))
            pytest.fail(f"cloud-init output does not match fixture:\n{diff[:3000]}")


# ---------------------------------------------------------------------------
# 3. State file write/read roundtrip
# ---------------------------------------------------------------------------

class TestStateFile:
    def test_save_and_load_roundtrip(self, tmp_path):
        state = ProvisionState(
            slug="testop",
            instance_name="openclaw-testop",
            static_ip="203.0.113.100",
            tailscale_ip="100.64.1.100",
            aws_region="us-west-2",
            domain="example2.com",
            runbook_sections_complete=["preflight", "keypair", "instance"],
        )
        out = state.save(tmp_path)
        assert out.exists()

        loaded = ProvisionState.load(out)
        assert loaded.slug == "testop"
        assert loaded.static_ip == "203.0.113.100"
        assert loaded.tailscale_ip == "100.64.1.100"
        assert loaded.domain == "example2.com"
        assert "keypair" in loaded.runbook_sections_complete

    def test_json_is_valid(self, tmp_path):
        state = ProvisionState(slug="test", instance_name="openclaw-test")
        out = state.save(tmp_path)
        with open(out) as f:
            data = json.load(f)
        assert data["slug"] == "test"
        assert "timestamp_start" in data
        assert isinstance(data["runbook_sections_complete"], list)

    def test_state_dir_created_if_missing(self, tmp_path):
        nested = tmp_path / "a" / "b" / "state"
        state = ProvisionState(slug="s", instance_name="openclaw-s")
        out = state.save(nested)
        assert out.exists()

    def test_multiple_saves_are_idempotent(self, tmp_path):
        state = ProvisionState(slug="testop", instance_name="openclaw-testop")
        state.runbook_sections_complete.append("preflight")
        out1 = state.save(tmp_path)

        state.runbook_sections_complete.append("keypair")
        out2 = state.save(tmp_path)

        assert out1 == out2
        loaded = ProvisionState.load(out2)
        assert "keypair" in loaded.runbook_sections_complete


# ---------------------------------------------------------------------------
# 4. Dry-run output structure
# ---------------------------------------------------------------------------

class TestDryRunOutput:
    def test_preflight_records_calls(self, provisioner_dry, fake_ts_key, fake_operator_pubkey):
        provisioner_dry.preflight(fake_ts_key, fake_operator_pubkey)
        calls = provisioner_dry.planned_calls
        assert any("sts" in c or "get_regions" in c or "get_blueprints" in c for c in calls)

    def test_keypair_records_call(self, provisioner_dry):
        provisioner_dry.create_keypair()
        calls = provisioner_dry.planned_calls
        assert any("create_key_pair" in c or "get_key_pair" in c for c in calls)

    def test_instance_records_call(self, provisioner_dry):
        provisioner_dry.launch_instance("user_data: test")
        calls = provisioner_dry.planned_calls
        assert any("create_instances" in c or "get_instance" in c for c in calls)

    def test_static_ip_records_calls(self, provisioner_dry):
        provisioner_dry.allocate_static_ip()
        calls = provisioner_dry.planned_calls
        assert any("static_ip" in c.lower() for c in calls)
        # Dry-run static IP should be set
        assert provisioner_dry.state.static_ip != ""

    def test_firewall_records_calls(self, provisioner_dry):
        provisioner_dry.set_firewall(FIREWALL_INITIAL)
        calls = provisioner_dry.planned_calls
        assert any("put_instance_public_ports" in c for c in calls)

    def test_dns_skipped_with_flag(self, provisioner_dry):
        before = len(provisioner_dry.planned_calls)
        provisioner_dry.set_dns("1.2.3.4")
        # skip_dns=True → no Route53 calls
        assert len(provisioner_dry.planned_calls) == before

    def test_boot_wait_records_calls(self, provisioner_dry):
        provisioner_dry.wait_for_boot()
        calls = provisioner_dry.planned_calls
        assert any("get_instance" in c for c in calls)

    def test_cloud_init_wait_records_calls(self, provisioner_dry, fake_operator_pubkey):
        provisioner_dry.wait_for_cloud_init(fake_operator_pubkey)
        calls = provisioner_dry.planned_calls
        assert any("boot-finished" in c for c in calls)

    def test_tailscale_ip_set_in_dry_run(self, provisioner_dry):
        provisioner_dry.retrieve_tailscale_ip()
        assert provisioner_dry.state.tailscale_ip.startswith("100.")

    def test_post_boot_verify_returns_all_true(self, provisioner_dry):
        checks = provisioner_dry.verify_post_boot()
        assert all(checks.values()), f"Expected all checks True, got: {checks}"

    def test_sections_completed_after_full_dry_run(self, provisioner_dry, fake_ts_key,
                                                   fake_operator_pubkey, tmp_path):
        provisioner_dry.preflight(fake_ts_key, fake_operator_pubkey)
        provisioner_dry.create_keypair()
        provisioner_dry.launch_instance("userdata")
        provisioner_dry.allocate_static_ip()
        provisioner_dry.set_firewall(FIREWALL_INITIAL)
        provisioner_dry.set_dns(provisioner_dry.state.static_ip)
        provisioner_dry.wait_for_boot()
        provisioner_dry.wait_for_cloud_init(fake_operator_pubkey)
        provisioner_dry.retrieve_tailscale_ip()
        provisioner_dry.verify_post_boot()
        provisioner_dry.tighten_firewall()
        state_path = provisioner_dry.save_state(tmp_path)

        assert state_path.exists()
        loaded = ProvisionState.load(state_path)
        assert "preflight" in loaded.runbook_sections_complete
        assert "firewall_tightened" in loaded.runbook_sections_complete

    def test_planned_calls_are_non_empty_after_full_run(self, provisioner_dry, fake_ts_key,
                                                         fake_operator_pubkey, tmp_path):
        provisioner_dry.preflight(fake_ts_key, fake_operator_pubkey)
        provisioner_dry.create_keypair()
        provisioner_dry.launch_instance("userdata")
        provisioner_dry.allocate_static_ip()
        provisioner_dry.set_firewall(FIREWALL_INITIAL)
        provisioner_dry.wait_for_boot()
        provisioner_dry.wait_for_cloud_init(fake_operator_pubkey)
        provisioner_dry.retrieve_tailscale_ip()
        provisioner_dry.verify_post_boot()
        provisioner_dry.tighten_firewall()
        assert len(provisioner_dry.planned_calls) >= 10


# ---------------------------------------------------------------------------
# 5. Preflight validation edge cases
# ---------------------------------------------------------------------------

class TestPreflightValidation:
    def test_empty_tailscale_key_raises(self, provisioner_dry, fake_operator_pubkey):
        with pytest.raises(ValueError, match="empty"):
            provisioner_dry.preflight("", fake_operator_pubkey)

    def test_wrong_prefix_tailscale_key_raises(self, provisioner_dry, fake_operator_pubkey):
        with pytest.raises(ValueError, match="tskey-auth-"):
            provisioner_dry.preflight("tskey-client-WRONG-PREFIX", fake_operator_pubkey)

    def test_short_tailscale_key_raises(self, provisioner_dry, fake_operator_pubkey):
        with pytest.raises(ValueError, match="truncated"):
            provisioner_dry.preflight(f"{TAILSCALE_AUTH_KEY_PREFIX}short", fake_operator_pubkey)

    def test_empty_operator_pubkey_raises(self, provisioner_dry, fake_ts_key):
        with pytest.raises(ValueError, match="empty"):
            provisioner_dry.preflight(fake_ts_key, "")

    def test_invalid_pubkey_format_raises(self, provisioner_dry, fake_ts_key):
        with pytest.raises(ValueError, match="OpenSSH"):
            provisioner_dry.preflight(fake_ts_key, "not-a-real-pubkey")
