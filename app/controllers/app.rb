#!/usr/bin/env ruby
# frozen_string_literal: true

# frozen_string_literal: true

require 'sinatra/base'
require 'sparql/client'
require 'yaml'
require 'json'
require 'set'
require 'fileutils'

module Shallot
  class App < Sinatra::Base
    LOCAL_QUERY_DIR = ENV['QUERY_DIR'] || 'queries'
    DEFAULT_ENDPOINT = ENV['SPARQL_ENDPOINT'] || (File.exist?('endpoint.txt') ? File.read('endpoint.txt').strip : nil)

    PARAM_TYPES = {
      '' => { type: 'string' },
      'literal' => { type: 'string' },
      'langString' => { type: 'string' },
      'iri' => { type: 'string', format: 'uri' },
      'url' => { type: 'string', format: 'uri' },
      'integer' => { type: 'integer' },
      'float' => { type: 'number' },
      'double' => { type: 'number' },
      'boolean' => { type: 'boolean' },
      'date' => { type: 'string', format: 'date' },
      'dateTime' => { type: 'string', format: 'date-time' }
    }.freeze

    class Query
      attr_reader :route_path, :relative_path, :query_text, :decorators, :parameters,
                  :method, :pagination, :tags, :summary, :description,
                  :endpoint, :endpoint_in_url, :enumerations, :defaults

      def initialize(file_path)
        @file_path = file_path
        @relative_path = file_path.sub(/\A#{Regexp.escape(App::LOCAL_QUERY_DIR + File::SEPARATOR)}/, '').sub(/\.rq\z/, '')
        @route_path = '/' + @relative_path

        load_query_and_decorators
        extract_decorators
        extract_parameters
      end

      private

      def load_query_and_decorators
        lines = File.readlines(@file_path)
        decorator_lines = []
        query_lines = []
        in_decorators = true

        lines.each do |line|
          if in_decorators && line.strip.start_with?('#')
            decorator_lines << line
          else
            in_decorators = false
            query_lines << line
          end
        end

        decorator_text = decorator_lines.map { |l| l.sub(/^#\s*\+?\s*/, '') }.join
        @decorators = YAML.safe_load(decorator_text) || {}
        @query_text = query_lines.join
      end

      def extract_decorators
        @summary = @decorators['summary'] || ''
        @description = @decorators['description'] || ''
        @tags = Array(@decorators['tags'] || [])
        @method = (@decorators['method'] || 'GET').upcase
        @pagination = @decorators['pagination']&.to_i
        @endpoint = @decorators['endpoint']
        @endpoint_in_url = @decorators.fetch('endpoint_in_url', true)
        @enumerations = normalize_to_hash(@decorators['enumerate'])
        @defaults = normalize_to_hash(@decorators['defaults'])
      end

      def normalize_to_hash(data)
        return {} if data.nil?
        return data if data.is_a?(Hash)
        return data.inject({}) { |h, item| h.merge!(item.is_a?(Hash) ? item : {}) } if data.is_a?(Array)
        {}
      end

      def extract_parameters
        var_names = @query_text.scan(/\?([a-zA-Z0-9_]+)/).flatten.uniq
        @parameters = var_names.map do |full_var|
          if full_var =~ /^(.*)_(optional_.*)\z/
            name = $1
            suffix = $2
            required = false
          elsif full_var =~ /^(.*)_([^_]+)\z/
            name = $1
            suffix = $2
            required = true
          else
            name = full_var
            suffix = ''
            required = true
          end

          suffix = suffix.sub(/\Aoptional_/, '') if suffix.start_with?('optional_')
          type_info = App::PARAM_TYPES[suffix] || App::PARAM_TYPES['']

          {
            param_name: name,
            var_name: full_var,
            required: required,
            type: type_info[:type],
            format: type_info[:format],
            enum: @enumerations[name],
            default: @defaults[name]
          }
        end
      end
    end

    QUERIES = Dir.glob(File.join(LOCAL_QUERY_DIR, '**', '*.rq')).map { |f| Query.new(f) }

    # Dynamic routes for each query
    QUERIES.each do |q|
      send(q.method.downcase, q.route_path) do
        endpoint_url = q.endpoint || DEFAULT_ENDPOINT
        endpoint_url = params['endpoint'] if q.endpoint_in_url && params['endpoint']&.strip&.length&.positive?
        halt 400, 'No SPARQL endpoint configured' if endpoint_url.nil? || endpoint_url.empty?

        sparql = q.query_text.dup

        # Bind provided parameters
        q.parameters.each do |p|
          next unless params[p[:param_name]]&.strip&.length&.positive?

          value = params[p[:param_name]]

          bound = case p[:type]
                  when 'string'
                    p[:format] == 'uri' ? "<#{value}>" : "\"#{value.gsub('"', '\\"')}\""
                  when 'integer', 'number', 'boolean'
                    value
                  else
                    "\"#{value.gsub('"', '\\"')}\""
                  end

          sparql.gsub!(/\b\?#{Regexp.escape(p[:var_name])}\b/, bound)
        end

        # Pagination
        if q.pagination
          page = (params['page'] || '1').to_i.clamp(1, Float::INFINITY)
          limit = q.pagination
          offset = (page - 1) * limit
          sparql += " LIMIT #{limit + 1} OFFSET #{offset}"
        end

        client = SPARQL::Client.new(endpoint_url)
        result = client.query(sparql)

        # Handle SELECT (most common)
        if result.respond_to?(:map)
          vars = result.variable_names || []
          bindings = result.map do |sol|
            sol.to_h.transform_keys(&:to_s).transform_values do |term|
              h = { type: term.uri? ? 'uri' : 'literal', value: term.to_s }
              h['xml:lang'] = term.language.to_s if term.language
              h['datatype'] = term.datatype.to_s if term.datatype
              h
            end
          end

          has_next = q.pagination && bindings.size > q.pagination
          bindings.pop if has_next

          response_json = {
            head: { vars: vars },
            results: { bindings: bindings }
          }

          if q.pagination
            base = request.url.split('?').first
            links = []
            links << "<#{base}?page=#{page - 1}>; rel=\"previous\"" if page > 1
            links << "<#{base}?page=#{page + 1}>; rel=\"next\"" if has_next
            headers['Link'] = links.join(', ') if links.any?
          end

          content_type :json
          response_json.to_json
        else
          # ASK or other
          content_type :json
          { head: {}, boolean: !!result }.to_json
        end
      end
    end

    get '/' do
      content_type 'text/html'
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>Shallot API</title>
          <style>body { margin: 0; }</style>
        </head>
        <body>
          <redoc spec-url="/spec.yaml"></redoc>
          <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
        </body>
        </html>
      HTML
    end

    get '/spec.yaml' do
      content_type 'text/yaml'

      openapi = {
        openapi: '3.0.3',
        info: {
          title: 'Shallot Local API',
          description: 'OpenAPI generated from local SPARQL queries',
          version: '1.0.0'
        },
        servers: [{ url: request.base_url }],
        paths: {},
        tags: []
      }

      tag_set = Set.new

      QUERIES.each do |q|
        tag_set.merge(q.tags)

        path_item = (openapi[:paths][q.route_path] ||= {})
        operation = {
          summary: q.summary.presence || q.relative_path,
          description: q.description.presence || "SPARQL query: #{q.relative_path}.rq",
          tags: q.tags,
          parameters: q.parameters.map do |p|
            schema = { type: p[:type] }
            schema[:format] = p[:format] if p[:format]
            schema[:enum] = p[:enum] if p[:enum]
            param = {
              name: p[:param_name],
              in: 'query',
              required: p[:required],
              schema: schema
            }
            param[:default] = p[:default] if p[:default]
            param
          end,
          responses: {
            '200' => {
              description: 'SPARQL result',
              content: { 'application/json' => { schema: { type: 'object' } } }
            }
          }
        }

        if q.endpoint_in_url
          operation[:parameters] << {
            name: 'endpoint',
            in: 'query',
            schema: { type: 'string', format: 'uri' },
            description: 'Override SPARQL endpoint'
          }
        end

        if q.pagination
          operation[:parameters] << {
            name: 'page',
            in: 'query',
            schema: { type: 'integer', minimum: 1, default: 1 }
          }
        end

        path_item[q.method.downcase.to_sym] = operation
      end

      openapi[:tags] = tag_set.map { |t| { name: t } }.sort_by { |t| t[:name] }

      openapi.to_yaml
    end
  end
end


$LOAD_PATH.unshift(File.expand_path('../src', __dir__))

require 'shallot-light/app/controllers/app.rb'

Shallot::App.run!
