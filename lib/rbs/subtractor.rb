# frozen_string_literal: true

module RBS
  class Subtractor
    # TODO: Should minuend consider use directive?
    def initialize(minuend, subtrahend)
      @minuend = minuend
      @subtrahend = subtrahend
    end

    def call(minuend = @minuend, context: nil)
      minuend.filter_map do |decl|
        case decl
        when AST::Declarations::Constant
          name = absolute_typename(decl.name, context: context)
          decl unless @subtrahend.constant_name?(name)
        when AST::Declarations::Interface
          name = absolute_typename(decl.name, context: context)
          decl unless @subtrahend.interface_name?(name)
        when AST::Declarations::Class, AST::Declarations::Module
          filter_members(decl, context: context)
        when AST::Declarations::Global
          decl unless @subtrahend.global_decls[decl.name]
        when AST::Declarations::TypeAlias
          name = absolute_typename(decl.name, context: context)
          decl unless @subtrahend.type_alias_decls[name]
        when AST::Declarations::ClassAlias
          name = absolute_typename(decl.new_name, context: context)
          decl unless @subtrahend.class_alias?(name) || @subtrahend.class_decl?(name)
        when AST::Declarations::ModuleAlias
          name = absolute_typename(decl.new_name, context: context)
          decl unless @subtrahend.module_alias?(name) || @subtrahend.module_decl?(name)
        else
          raise "unknwon decl: #{(_ = decl).class}"
        end
      end
    end

    private def filter_members(decl, context:)
      # @type var children: Array[RBS::AST::Declarations::t | RBS::AST::Members::t]
      children = []
      owner = absolute_typename(decl.name, context: context)

      case decl
      when AST::Declarations::Class, AST::Declarations::Module
        children.concat(call(decl.each_decl.to_a, context: [context, decl.name]))
        children.concat(decl.each_member.reject { |m| member_exist?(owner, m, context: context) })
      else
        raise "unknwon decl: #{(_ = decl).class}"
      end

      update_decl(decl, members: children)
    end

    # TODO: Is context used?
    private def member_exist?(owner, member, context:)
      case member
      when AST::Members::MethodDefinition
        method_exist?(owner, member.name, member.kind)
      when AST::Members::Alias
        method_exist?(owner, member.new_name, member.kind)
      when AST::Members::AttrReader
        method_exist?(owner, member.name, member.kind)
      when AST::Members::AttrWriter
        method_exist?(owner, :"#{member.name}=", member.kind)
      when AST::Members::AttrAccessor
        # TODO: It unexpectedly removes attr_accessor even if either reader or writer does not exist in the subtrahend.
        method_exist?(owner, member.name, member.kind) || method_exist?(owner, :"#{member.name}=", member.kind)
      when AST::Members::InstanceVariable
        ivar_exist?(owner, member.name, :instance)
      when AST::Members::ClassInstanceVariable
        ivar_exist?(owner, member.name, :singleton)
      when AST::Members::ClassVariable
        cvar_exist?(owner, member.name)
      when AST::Members::Include, AST::Members::Extend, AST::Members::Prepend
        # Duplicated mixin is allowed. So do nothing
        false
      when AST::Members::Public, AST::Members::Private
        # They should not be removed even if the subtrahend has them.
        false
      else
        raise "unknown member: #{(_ = member).class}"
      end
    end

    private def method_exist?(owner, method_name, kind)
      each_member(owner).any? do |m|
        case m
        when AST::Members::MethodDefinition
          m.name == method_name && m.kind == kind
        when AST::Members::Alias
          m.new_name == method_name && m.kind == kind
        when AST::Members::AttrReader
          m.name == method_name && m.kind == kind
        when AST::Members::AttrWriter
          :"#{m.name}=" == method_name && m.kind == kind
        when AST::Members::AttrAccessor
          (m.name == method_name || :"#{m.name}=" == method_name) && m.kind == kind
        end
      end
    end

    private def ivar_exist?(owner, name, kind)
      each_member(owner).any? do |m|
        case m
        when AST::Members::InstanceVariable
          m.name == name
        when AST::Members::Attribute
          ivar_name = m.ivar_name == false ? nil : m.ivar_name || :"@#{m.name}"
          ivar_name == name && m.kind == kind
        end
      end
    end

    private def cvar_exist?(owner, name)
      each_member(owner).any? do |m|
        case m
        when AST::Members::ClassVariable
          m.name == name
        end
      end
    end

    private def each_member(owner, &block)
      return enum_for((__method__ or raise), owner) unless block

      decls =
        if owner.interface?
          entry = @subtrahend.interface_decls[owner]
          return unless entry
          [entry.decl]
        else
          entry = @subtrahend.class_decls[owner]
          return unless entry
          entry.decls.map { |d| d.decl }
        end

      # TODO: performance
      decls.each { |d| d.members.each { |m| block.call(m) } }
    end

    private def update_decl(decl, members:)
      case decl
      when AST::Declarations::Class
        decl.class.new(name: decl.name, type_params: decl.type_params, super_class: decl.super_class,
                        annotations: decl.annotations, location: decl.location, comment: decl.comment,
                        members: members)
      when AST::Declarations::Module
        decl.class.new(name: decl.name, type_params: decl.type_params, self_types: decl.self_types,
                        annotations: decl.annotations, location: decl.location, comment: decl.comment,
                        members: members)
      end
    end

    private def absolute_typename(name, context:)
      while context
        ns = context[1] or raise
        name = name.with_prefix(ns.to_namespace)
        context = _ = context[0]
      end
      name.absolute!
    end
  end
end
