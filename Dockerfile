# On-Call Manager container image (Linux). Listens on HTTPS 8443 with Webex sign-in.
# Build:  docker build -t oncall .
# Run:    see docker-compose.yml and the README "Container" section.
FROM mcr.microsoft.com/powershell:lts-7.4-ubuntu-22.04

# tzdata: Windows and IANA time zone IDs. Pode from PSGallery, pinned.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata \
 && rm -rf /var/lib/apt/lists/* \
 && pwsh -NoProfile -Command "$ErrorActionPreference = 'Stop'; \
      if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { Register-PSRepository -Default }; \
      Install-Module Pode -RequiredVersion 2.14.1 -Scope AllUsers -Force -Repository PSGallery; \
      Import-Module Pode" \
 && useradd --create-home --uid 10001 oncall

WORKDIR /app
# Only what the app runs. Never `COPY .`: data/, keys and tests stay out of the image.
COPY Start-OnCall.ps1 Install-OnCall.ps1 Test-Webex.ps1 Test-Schedule.ps1 VERSION config.example.json /app/
COPY modules/ /app/modules/
COPY public/ /app/public/
RUN mkdir -p /app/data /app/logs && chown oncall:oncall /app/data /app/logs

# ONCALL_REQUIRE_MASTER_KEY=1: refuse to start without the oncall_master_key secret, so keys
# are never encrypted with a throwaway key that disappears with the container.
ENV ONCALL_LISTEN=Network \
    ONCALL_PORT=8443 \
    ONCALL_DATA=/app/data \
    ONCALL_REQUIRE_MASTER_KEY=1

USER oncall
EXPOSE 8443
VOLUME ["/app/data"]
ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-File", "/app/Start-OnCall.ps1"]
