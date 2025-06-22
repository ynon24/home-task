from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/service-b')
def service_b():
    """Service B endpoint with minimal friendly content"""
    return jsonify({
        "message": "welcome to service b. I do nothing :)",
        "service": "service-b",
        "status": "doing absolutely nothing as designed"
    })

# Optional: Keep health check for Kubernetes
@app.route('/health')
def health_check():
    """Health check for Kubernetes probes"""
    return jsonify({"status": "healthy", "service": "service-b"})

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=8080, debug=False)