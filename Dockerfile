#FROM ruby:3.1.4
FROM ruby:3.4.1

RUN apt-get update
# RUN apt-get install plantuml

# Install gems
ENV APP_HOME="/app"
ENV HOME="/root"

RUN cp /usr/share/zoneinfo/CET /etc/localtime 

RUN mkdir $APP_HOME
WORKDIR $APP_HOME
COPY Gemfile ./
COPY solis.gemspec ./
COPY Rakefile ./
COPY ./lib /app/lib

RUN gem install bundler
RUN bundle install

RUN mkdir /app/data/ ; mkdir /app/data/input 

COPY ./examples/*.rb /app/

