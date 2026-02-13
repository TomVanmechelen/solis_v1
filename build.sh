#!/bin/bash

if [ ! -f ".env" ]; then
   echo "Please create an .env file with a SERVICE, REGISTRY and NAMESPACE parameter"
   exit 1
fi

source .env

if [ -z $REGISTRY ]; then
   echo "Please set REGISTRY in .env"
   exit 1
fi

if [ -z $SERVICE ]; then
   echo "Please set SERVICE in .env"
   exit 1
fi

if [ -z $NAMESPACE ]; then
   echo "Please set NAMESPACE in .env"
   exit 1
fi

if [ -z $VERSION_TAG ]; then
   echo "Please set NAMVERSION_TAGESPACE in .env"
   exit 1
fi

function build {
   echo "Building $SERVICE"
   docker build -f Dockerfile --tag $NAMESPACE/$SERVICE:$VERSION_TAG .
   docker tag $NAMESPACE/$SERVICE:$VERSION_TAG $REGISTRY/$NAMESPACE/$SERVICE:$VERSION_TAG
}

function push {
   echo "Pushing $SERVICE"
   if [ -z $VERSION_TAG ]; then
     echo "$NAMESPACE/$SERVICE $REGISTRY/$NAMESPACE/$SERVICE"
     docker tag $NAMESPACE/$SERVICE $REGISTRY/$NAMESPACE/$SERVICE
     docker push $REGISTRY/$NAMESPACE/$SERVICE
   else
    echo "Pushing with version tag $VERSION_TAG"
    echo "$NAMESPACE/$SERVICE $REGISTRY/$NAMESPACE/$SERVICE:$VERSION_TAG"
    docker tag $NAMESPACE/$SERVICE $REGISTRY/$NAMESPACE/$SERVICE:$VERSION_TAG
    docker push $REGISTRY/$NAMESPACE/$SERVICE:$VERSION_TAG
   fi   
}

case $1 in
"push")
  build
  push
  ;;
*)
  build
  ;;
esac

echo
echo
if [ -z "$DEBUG" ]; then
   echo "docker run $NAMESPACE/$SERVICE"
else
   echo "docker run -e DEBUG=1 $NAMESPACE/$SERVICE"
fi
