from locust import HttpUser, task, between

class JellyfinUser(HttpUser):
    wait_time = between(0.1, 0.5)  # Simulate a fast-clicking user

    @task
    def load_homepage(self):
        # We use the Cluster-IP directly to avoid DNS issues
        self.client.get("/")