FROM ruby:3.4.10-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libyaml-dev curl && rm -rf /var/lib/apt/lists/*
WORKDIR /rails
ENV RAILS_ENV=production BUNDLE_WITHOUT="development:test" SECRET_KEY_BASE_DUMMY=1
COPY gem/ /gem/
COPY app/Gemfile app/Gemfile.lock ./
RUN bundle install -j4
COPY app/ ./
CMD ["sh", "-c", "bin/rails db:prepare >/dev/null && exec bin/rails server -b 0.0.0.0 -p 3000"]
