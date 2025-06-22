FROM python:3.11-slim

WORKDIR /server

# Copy requirements first for better caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY server.py .

# Expose port 8080
EXPOSE 8080

# Run the application
CMD ["python", "server.py"]