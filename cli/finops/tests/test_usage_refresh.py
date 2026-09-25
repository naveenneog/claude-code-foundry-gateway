from copy import deepcopy
import pytest
from claude_finops.config import Config
from claude_finops.errors import FinOpsError


def job():
    return dict(id="/subscriptions/contoso/resourceGroups/rg-contoso/providers/Microsoft.App/jobs/publisher",
        name="publisher", properties=dict(configuration=dict(triggerType="Schedule"),
        template=dict(containers=[dict(name="turnstile", image="trusted-existing-image", command=[
            "/bin/bash", "-c", 'setup\n/opt/pwsh/pwsh -NoProfile -File ./scripts/Invoke-ClaudeTurnstileSchedule.ps1 -ResourceGroup "${CLAUDE_RG}" ${extra}\n'],
            env=[dict(name="CLAUDE_RG", value="rg-contoso"), dict(name="CLAUDE_APIM", value="apim-contoso"),
                 dict(name="TURNSTILE_SKIP_EXPORT", value="false")], resources=dict(cpu=1, memory="2Gi"))])))


def test_one_execution_export_override_preserves_job_and_never_runs_governance():
    from claude_finops.usage_refresh import execution_plan
    original = job()
    original["properties"]["template"]["volumes"] = []
    original["properties"]["template"]["containers"][0]["imageType"] = "ContainerImage"
    before = deepcopy(original)
    plan, template = execution_plan([original], Config(resource_group="rg-contoso", apim_name="apim-contoso"),
                                    "2026-09-25T07:30:00Z", "2026-09-25T07:40:00Z")
    assert original == before
    assert "volumes" not in template
    assert "imageType" not in template["containers"][0]
    script = template["containers"][0]["command"][2]
    assert "Export-ClaudeTurnstileUsage.ps1" in script and "-NoCacheEvents" in script
    assert "Invoke-ClaudeTurnstileSchedule.ps1" not in script
    assert "-From 2026-09-25T07:30:00Z" in script and "-To 2026-09-25T07:40:00Z" in script
    assert plan["changes_job_definition"] is False


def test_ambiguous_publisher_and_unsafe_time_are_refused():
    from claude_finops.usage_refresh import execution_plan
    config = Config(resource_group="rg-contoso", apim_name="apim-contoso")
    with pytest.raises(FinOpsError):
        execution_plan([job(), job()], config, "2026-09-25", "2026-09-26")
    with pytest.raises(FinOpsError):
        execution_plan([job()], config, "today;whoami", "2026-09-26")
