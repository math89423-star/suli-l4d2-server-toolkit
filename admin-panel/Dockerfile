FROM python:3-slim

# Switch to Aliyun mirror for faster downloads in China
RUN sed -i 's|http://deb.debian.org/debian|http://mirrors.aliyun.com/debian|g' /etc/apt/sources.list.d/debian.sources

# Add non-free to existing sources (for steamcmd) instead of creating duplicate entries
RUN sed -i 's/Components: main/Components: main non-free/g' /etc/apt/sources.list.d/debian.sources

# Pre-accept Steam license to avoid interactive prompt
RUN echo "steamcmd steam/question select I AGREE" | debconf-set-selections \
    && echo "steamcmd steam/license note" | debconf-set-selections

# System deps: unzip (ZIP extraction), binutils (strings for VPK map names), steamcmd (workshop downloads)
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        unzip \
        binutils \
        ca-certificates \
        steamcmd:i386 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/gameservers/l4d2/admin-panel

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 5000
CMD ["python3", "app.py"]
