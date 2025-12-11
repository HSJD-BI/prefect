# flows/sample_flow.py
from prefect import flow, get_run_logger
import os

@flow(log_prints=True)
def sample_flow(name: str = "world"):
    logger = get_run_logger()
    env = os.getenv("EXECUTION_ENV", "dev")
    logger.info(f"Hello, {name}! Running in {env}.")
    return {"greeting": f"Hello, {name}!", "env": env}

if __name__ == "__main__":
    # local dev run (not via deployment)
    sample_flow()

