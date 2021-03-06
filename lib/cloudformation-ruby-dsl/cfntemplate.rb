# Copyright 2013-2014 Bazaarvoice, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'cloudformation-ruby-dsl/dsl'

unless RUBY_VERSION >= '1.9'
  # This script uses Ruby 1.9 functions such as Enumerable.slice_before and Enumerable.chunk
  $stderr.puts "This script requires ruby 1.9+.  On OS/X use Homebrew to install ruby 1.9:"
  $stderr.puts "  brew install ruby"
  exit(2)
end

require 'rubygems'
require 'json'
require 'yaml'
require 'erb'
require 'aws-sdk'
require 'diffy'

############################# AWS SDK Support

class AwsCfn
  attr_accessor :cfn_client_instance

  def cfn_client
    if @cfn_client_instance == nil
        # region and credentials are loaded from the environment; see http://docs.aws.amazon.com/sdkforruby/api/Aws/CloudFormation/Client.html
        @cfn_client_instance = Aws::CloudFormation::Client.new(
        # we don't validate parameters because the aws-ruby-sdk gets a number parameter and expects it to be a string and fails the validation
        # see: https://github.com/aws/aws-sdk-ruby/issues/848
        validate_params: false,
      )
    end
    @cfn_client_instance
  end
end

############################# Command-line support

# Parse command-line arguments and return the parameters and region
def parse_args
  stack_name = nil
  parameters = {}
  region     = default_region
  nopretty   = false
  ARGV.slice_before(/^--/).each do |name, value|
    case name
    when '--stack-name'
      stack_name = value
    when '--parameters'
      parameters = Hash[value.split(/;/).map { |pair| pair.split(/=/, 2) }]  #/# fix for syntax highlighting
    when '--region'
      region = value
    when '--nopretty'
      nopretty = true
    end
  end
  [stack_name, parameters, region, nopretty]
end

def cfn(template)
  aws_cfn = AwsCfn.new
  cfn_client = aws_cfn.cfn_client

  action = ARGV[0]
  deprecated = {
    "cfn-validate-template" => "validate",
    "cfn-create-stack" => "create",
    "cfn-update-stack" => "update"
  }
  if deprecated.keys.include? action
    replacement = deprecated[action]
    $stderr.puts "WARNING: '#{action}' is deprecated and will be removed; use '#{replacement}' instead"
    action = replacement
  end
  unless %w(expand diff validate create update).include? action
    $stderr.puts "usage: #{$PROGRAM_NAME} <expand|diff|validate|create|update>"
    exit(2)
  end

  # Find parameters where extension attribute :Immutable is true then remove it from the
  # cfn template since we can't pass it to CloudFormation.
  immutable_parameters = template.excise_parameter_attribute!(:Immutable)

  # Tag CloudFormation stacks based on :Tags defined in the template.
  # Remove them from the template as well, so that the template is valid.
  cfn_tags = template.excise_tags!

  if action == 'diff' or (action == 'expand' and not template.nopretty)
    template_string = JSON.pretty_generate(template)
  else
    template_string = JSON.generate(template)
  end

  # Derive stack name from ARGV
  _, options = extract_options(ARGV[1..-1], %w(--nopretty), %w(--stack-name --region --parameters --tag))
  # If the first argument is not an option and stack_name is undefined, assume it's the stack name
  if template.stack_name.nil?
    stack_name = options.shift if options[0] && !(/^-/ =~ options[0])
  else
    stack_name = template.stack_name
  end

  case action
  when 'expand'
    # Write the pretty-printed JSON template to stdout and exit.  [--nopretty] option writes output with minimal whitespace
    # example: <template.rb> expand --parameters "Env=prod" --region eu-west-1 --nopretty
    if template.nopretty
      puts template_string
    else
      puts template_string
    end
    exit(true)

  when 'diff'
    # example: <template.rb> diff my-stack-name --parameters "Env=prod" --region eu-west-1
    # Diff the current template for an existing stack with the expansion of this template.

    # We default to "output nothing if no differences are found" to make it easy to use the output of the diff call from within other scripts
    # If you want output of the entire file, simply use this option with a large number, i.e., -U 10000
    # In fact, this is what Diffy does by default; we just don't want that, and we can't support passing arbitrary options to diff
    # because Diffy's "context" configuration is mutually exclusive with the configuration to pass arbitrary options to diff
    if !options.include? '-U'
      options.push('-U', '0')
    end

    # Ensure a stack name was provided
    if stack_name.empty?
      $stderr.puts "Error: a stack name is required"
      exit(false)
    end

    # describe the existing stack
    begin
      old_template_body = cfn_client.get_template({stack_name: stack_name}).template_body
    rescue Aws::CloudFormation::Errors::ValidationError => e
      $stderr.puts "Error: #{e}"
      exit(false)
    end

    # parse the string into a Hash, then convert back into a string; this is the only way Ruby JSON lets us pretty print a JSON string
    old_template   = JSON.pretty_generate(JSON.parse(old_template_body))
    # there is only ever one stack, since stack names are unique
    old_attributes = cfn_client.describe_stacks({stack_name: stack_name}).stacks[0]
    old_tags       = old_attributes.tags
    old_parameters = old_attributes.parameters

    # Sort the tag strings alphabetically to make them easily comparable
    old_tags_string = old_tags.sort.map { |tag| %Q(TAG "#{tag.key}=#{tag.value}"\n) }.join
    tags_string     = cfn_tags.sort.map { |tag| "TAG \"#{tag}\"\n" }.join

    # Sort the parameter strings alphabetically to make them easily comparable
    old_parameters_string = old_parameters.sort! {|pCurrent, pNext| pCurrent.parameter_key <=> pNext.parameter_key }.map { |param| %Q(PARAMETER "#{param.parameter_key}=#{param.parameter_value}"\n) }.join
    parameters_string     = template.parameters.sort.map { |key, value| "PARAMETER \"#{key}=#{value}\"\n" }.join

    # set default diff options
    Diffy::Diff.default_options.merge!(
      :diff    => "#{options.join(' ')}",
    )
    # set default diff output
    Diffy::Diff.default_format = :color

    tags_diff     = Diffy::Diff.new(old_tags_string, tags_string).to_s.strip!
    params_diff   = Diffy::Diff.new(old_parameters_string, parameters_string).to_s.strip!
    template_diff = Diffy::Diff.new(old_template, template_string).to_s.strip!

    if !tags_diff.empty?
      puts "====== Tags ======"
      puts tags_diff
      puts "=================="
      puts
    end

    if !params_diff.empty?
      puts "====== Parameters ======"
      puts params_diff
      puts "========================"
      puts
    end

    if !template_diff.empty?
      puts "====== Template ======"
      puts template_diff
      puts "======================"
      puts
    end

    exit(true)

  when 'validate'
    begin
      valid = cfn_client.validate_template({template_body: template_string})
      exit(valid.successful?)
    rescue Aws::CloudFormation::Errors::ValidationError => e
      $stderr.puts "Validation error: #{e}"
      exit(false)
    end

  when 'create'

    begin
      create_result = cfn_client.create_stack({
          stack_name: stack_name,
          template_body: template_string,
          parameters: template.parameters.map { |k,v| {parameter_key: k, parameter_value: v}}.to_a,
          tags: cfn_tags.map { |k,v| {"key" => k.to_s, "value" => v} }.to_a,
          capabilities: ["CAPABILITY_IAM"],
        })
      if create_result.successful?
        puts create_result.stack_id
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed to create stack: #{e}"
      exit(false)
    end

  when 'update'

    # Run CloudFormation command to describe the existing stack
    old_stack = cfn_client.describe_stacks({stack_name: stack_name}).stacks

    # this might happen if, for example, stack_name is an empty string and the Cfn client returns ALL stacks
    if old_stack.length > 1
      $stderr.puts "Error: found too many stacks with this name. There should only be one."
      exit(false)
    else
      # grab the first (and only) result
      old_stack = old_stack[0]
    end

    # If updating a stack and some parameters are marked as immutable, fail if the new parameters don't match the old ones.
    if not immutable_parameters.empty?
      old_parameters = Hash[old_stack.parameters.map { |p| [p.parameter_key, p.parameter_value]}]
      new_parameters = template.parameters

      immutable_parameters.sort.each do |param|
        if old_parameters[param].to_s != new_parameters[param].to_s
          $stderr.puts "Error: unable to update immutable parameter " +
                           "'#{param}=#{old_parameters[param]}' to '#{param}=#{new_parameters[param]}'."
          exit(false)
        end
      end
    end

    # Tags are immutable in CloudFormation.  Validate against the existing stack to ensure tags haven't changed.
    # Compare the sorted arrays for an exact match
    old_cfn_tags = old_stack.tags.map { |p| [p.key.to_sym, p.value]}
    cfn_tags_ary = cfn_tags.to_a
    if cfn_tags_ary.sort != old_cfn_tags
      $stderr.puts "CloudFormation stack tags do not match and cannot be updated. You must either use the same tags or create a new stack." +
                      "\n" + (old_cfn_tags - cfn_tags_ary).map {|tag| "< #{tag}" }.join("\n") +
                      "\n" + "---" +
                      "\n" + (cfn_tags_ary - old_cfn_tags).map {|tag| "> #{tag}"}.join("\n")
      exit(false)
    end

    # update the stack
    begin
      update_result = cfn_client.update_stack({
          stack_name: stack_name,
          template_body: template_string,
          parameters: template.parameters.map { |k,v| {parameter_key: k, parameter_value: v}}.to_a,
          capabilities: ["CAPABILITY_IAM"],
        })
      if update_result.successful?
        puts update_result.stack_id
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed to update stack: #{e}"
      exit(false)
    end

  end
end

# extract options and arguments from a command line string
#
# Example:
#
# desired, unknown = extract_options("arg1 --option withvalue --optionwithoutvalue", %w(--option), %w())
# 
# puts desired => Array{"arg1", "--option", "withvalue"}
# puts unknown => Array{}
#
# @param args
#   the Array of arguments (split the command line string by whitespace)
# @param opts_no_val
#   the Array of options with no value, i.e., --force
# @param opts_1_val
#   the Array of options with exaclty one value, i.e., --retries 3
# @returns
#   an Array of two Arrays.
#   The first array contains all the options that were extracted (both those with and without values) as a flattened enumerable.
#   The second array contains all the options that were not extracted.
def extract_options(args, opts_no_val, opts_1_val)
  args = args.clone
  opts = []
  rest = []
  while (arg = args.shift) != nil
    if opts_no_val.include?(arg)
      opts.push(arg)
    elsif opts_1_val.include?(arg)
      opts.push(arg)
      opts.push(arg) if (arg = args.shift) != nil
    else
      rest.push(arg)
    end
  end
  [opts, rest]
end

##################################### Additional dsl logic
# Core interpreter for the DSL
class TemplateDSL < JsonObjectDSL
  def exec!()
    cfn(self)
  end
end

# Main entry point
def template(&block)
  stack_name, parameters, aws_region, nopretty = parse_args
  raw_template(parameters, stack_name, aws_region, nopretty, &block)
end
