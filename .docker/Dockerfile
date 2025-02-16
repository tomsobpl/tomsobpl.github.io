FROM squidfunk/mkdocs-material:9.6.4

# Set the build arguments
ARG DOCKER_USER=app
ARG DOCKER_USER_ID=1000
ARG DOCKER_GROUP=app
ARG DOCKER_GROUP_ID=1000

# Create a user and group to run our app using the same id as the host user
# This is to avoid permission issues between the host and the container
RUN addgroup -g ${DOCKER_GROUP_ID} ${DOCKER_GROUP} \
    && adduser -D -u ${DOCKER_USER_ID} -G ${DOCKER_GROUP} ${DOCKER_USER}

# Tell docker that all future commands should run as the app user
USER ${DOCKER_USER}
