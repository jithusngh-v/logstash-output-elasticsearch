# Dockerfile for building Logstash with modified logstash-output-elasticsearch plugin
# This image includes the dynamic ILM feature for per-container index management
# Based on opensearchproject/logstash-oss-with-opensearch-output-plugin:8.4.0

ARG LOGSTASH_VERSION=8.4.0
FROM opensearchproject/logstash-oss-with-opensearch-output-plugin:${LOGSTASH_VERSION}

# Metadata labels for the image
LABEL maintainer="your-team@company.com" \
      description="Logstash with Dynamic ILM Elasticsearch Output Plugin" \
      version="12.1.1" \
      plugin.version="12.1.1" \
      logstash.version="8.4.0"

USER root

# Install build dependencies (including dos2unix for line ending conversion)
RUN apt-get update && \
    apt-get install -y gcc make ruby-dev dos2unix && \
    rm -rf /var/lib/apt/lists/*

# Remove existing elasticsearch output plugin
RUN /usr/share/logstash/bin/logstash-plugin remove logstash-output-elasticsearch || true

# Copy the modified plugin source
COPY --chown=logstash:logstash . /tmp/logstash-output-elasticsearch/

WORKDIR /tmp/logstash-output-elasticsearch

# Convert Windows line endings to Unix (CRLF -> LF)
RUN find /tmp/logstash-output-elasticsearch -type f \( -name "*.rb" -o -name "*.gemspec" \) -exec dos2unix {} \;

# Build the gem using system gem (since we installed ruby-dev)
RUN gem build logstash-output-elasticsearch.gemspec

ENV LS_JAVA_OPTS="-Xms2g -Xmx2g"

# Install the built gem using logstash-plugin
RUN /usr/share/logstash/bin/logstash-plugin install --no-verify /tmp/logstash-output-elasticsearch/logstash-output-elasticsearch-*.gem

# Clean up build dependencies and temporary files
RUN rm -rf /tmp/logstash-output-elasticsearch && \
    apt-get remove -y gcc make ruby-dev dos2unix && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/share/logstash

# Verify plugin installation
RUN /usr/share/logstash/bin/logstash-plugin list | grep logstash-output-elasticsearch

USER logstash

# Health check to ensure Logstash is running
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:9600/ || exit 1

# Default command (can be overridden in Kubernetes)
CMD ["/usr/share/logstash/bin/logstash"]
