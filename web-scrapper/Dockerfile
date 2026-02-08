FROM mcr.microsoft.com/playwright/python:v1.40.0-jammy

WORKDIR /app

# FIX: Explicitly install playwright (matching the image version) 
# along with redis and beautifulsoup
RUN pip install redis beautifulsoup4 playwright==1.40.0

COPY worker.py .

# Create the mount point for the PVC
RUN mkdir -p /mnt/data

# Run unbuffered to see logs in K8s immediately
CMD ["python", "-u", "worker.py"]