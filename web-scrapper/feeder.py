import redis

# Connect to localhost because docker-compose mapped port 6379
r = redis.Redis(host='localhost', port=6379, db=0)

# List of URLs to scrape
urls_to_scrape = [
    "https://www.wikipedia.org",
    "https://www.python.org",
    "https://news.ycombinator.com",
    "https://kubernetes.io",
]

print(f"Pushing {len(urls_to_scrape)} URLs to the queue...")

for url in urls_to_scrape:
    r.lpush("scrape_queue", url)

print("Done! Check your worker logs.")