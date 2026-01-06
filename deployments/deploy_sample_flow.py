# deployments/deploy_sample_flow.py
from prefect import flow

if __name__ == "__main__":
    # Create/update deployment
    flow.from_source(
        source="https://github.com/TomasGo002/test-deployment.git",
        entrypoint="workflow_test.py:github_stars"
    ).deploy(
        name="sample-deployment-local",
        work_pool_name="local-pool",
        parameters={"repos": ["PrefectHQ/prefect"]}
    )
    print("Deployment created: sample-deployment -> local-pool")

