#!/bin/bash

# Jenkins Docker Setup Script (Refactored for robustness and usability)

# 1. Check if Docker CLI is installed
if ! command -v docker &> /dev/null; then
  echo "Error: Docker is not installed or not available in PATH. Please install Docker and try again."
  exit 1
fi

# 2. Check if Docker daemon is running (this requires Docker CLI to be able to contact the daemon)
if ! docker info > /dev/null 2>&1; then
  echo "Error: Docker daemon is not running or is not accessible. Please start the Docker service and ensure your user has permission (e.g., in the docker group)."
  exit 1
fi
echo "Docker is installed and the daemon is running."

# 3. Check if required ports are available (2376 for Docker daemon, 8080 for Jenkins UI, 50000 for Jenkins agent communication)
REQUIRED_PORTS=(2376 8080 50000)
for PORT in "${REQUIRED_PORTS[@]}"; do
  # Check if anything is listening on the port
  if lsof -Pi :"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "Error: Required port $PORT is already in use on this system. Please free up port $PORT or change the configuration before proceeding."
    exit 1
  fi
done
echo "Ports ${REQUIRED_PORTS[*]} are free to use."

# 4. Check if the Docker network 'jenkins' exists
NETWORK_NAME="jenkins"
if docker network inspect "$NETWORK_NAME" > /dev/null 2>&1; then
  echo "Docker network '$NETWORK_NAME' already exists."
  read -p "Do you want to delete and recreate the '$NETWORK_NAME' network? [y/N]: " resp_net
  if [[ "$resp_net" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo "Removing existing Docker network '$NETWORK_NAME'..."
    docker network rm "$NETWORK_NAME"
    # Recreate the network
    echo "Recreating Docker network '$NETWORK_NAME'..."
    docker network create "$NETWORK_NAME"
  else
    echo "Keeping the existing Docker network '$NETWORK_NAME'."
    echo "Proceeding with the existing network."
  fi
else
  # Create the network if it doesn't exist
  echo "Creating Docker network '$NETWORK_NAME'..."
  docker network create "$NETWORK_NAME"
fi

# 5. Check if containers 'jenkins-docker' or 'jenkins-blueocean' already exist
DOCKER_CONT="jenkins-docker"     # Docker-in-Docker container name
JENKINS_CONT="jenkins-blueocean" # Jenkins container name
for CONT_NAME in "$DOCKER_CONT" "$JENKINS_CONT"; do
  # Use Docker to check if a container with this name exists (running or stopped)
  if [ "$(docker container ls -a -q -f name=^${CONT_NAME}$)" ]; then
    echo "Container '$CONT_NAME' already exists."
    read -p "Do you want to remove the existing container '$CONT_NAME'? [y/N]: " resp_cont
    if [[ "$resp_cont" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      echo "Stopping and removing container '$CONT_NAME'..."
      docker rm -f "$CONT_NAME" 2>/dev/null && echo "Removed container $CONT_NAME."
    else
      echo "Cannot continue with an existing container '$CONT_NAME'."
      echo "Please remove or rename the container and run the script again."
      exit 1
    fi
  fi
done

# 6. Build the Jenkins Blue Ocean Docker image (using docker build instead of docker buildx for simplicity)
echo "Building the Jenkins Blue Ocean Docker image (this may take a few minutes)..."
# Note: Assumes a Dockerfile is present in the current directory for Jenkins with Blue Ocean and Docker CLI.
docker build -t myjenkins-blueocean:latest . 
if [ $? -ne 0 ]; then
  echo "Docker image build failed. Please check the Dockerfile and try again."
  exit 1
fi
echo "Successfully built Docker image 'myjenkins-blueocean:latest'."

# 7. Run the Docker-in-Docker (DinD) container for Jenkins to use Docker
echo "Starting Docker daemon container ('$DOCKER_CONT')..."
docker run --name "$DOCKER_CONT" --detach --privileged \
  --network "$NETWORK_NAME" --network-alias docker \
  --env DOCKER_TLS_CERTDIR=/certs \
  --volume jenkins-docker-certs:/certs/client \
  --volume jenkins-data:/var/jenkins_home \
  --publish 2376:2376 docker:dind
if [ $? -ne 0 ]; then
  echo "Failed to start Docker (DinD) container. Ensure Docker image 'docker:dind' is available and Docker daemon supports this."
  exit 1
fi
echo "Docker DinD container '$DOCKER_CONT' is running."

# 8. Run the Jenkins Blue Ocean container connected to the Docker network and Docker daemon
echo "Starting Jenkins container ('$JENKINS_CONT')..."
docker run --name "$JENKINS_CONT" --detach --restart=on-failure \
  --network "$NETWORK_NAME" \
  --env DOCKER_HOST=tcp://docker:2376 \
  --env DOCKER_CERT_PATH=/certs/client \
  --env DOCKER_TLS_VERIFY=1 \
  --publish 8080:8080 --publish 50000:50000 \
  --volume jenkins-data:/var/jenkins_home \
  --volume jenkins-docker-certs:/certs/client:ro \
  myjenkins-blueocean:latest
if [ $? -ne 0 ]; then
  echo "Failed to start Jenkins container. Please check the Docker run commands and try again."
  exit 1
fi
echo "Jenkins container '$JENKINS_CONT' started successfully."

# 9. Final info message
echo "Setup complete! Jenkins is initializing."
echo "You can access Jenkins at: http://localhost:8080"
echo "To follow Jenkins startup logs: docker logs -f $JENKINS_CONT"
