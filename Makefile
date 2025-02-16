dc = docker compose

.PHONY: build up ps down ssh
build: # Rebuild docker stack
	${dc} build --build-arg DOCKER_USER_ID=$(shell id --user) --build-arg DOCKER_GROUP_ID=$(shell id --group)

up: # Start docker stack in detached mode
	${dc} up --detach --remove-orphans

ps: # Print docker stack status
	${dc} ps

down: # Stop docker stack
	${dc} down

ssh: # SSH into container for work
	${dc} exec mkdocs /bin/ash

.PHONY: rebuild restart
rebuild: down build up # Rebuild and restart docker stack
restart: down up # Restart docker stack
