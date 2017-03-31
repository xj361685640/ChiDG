module type_cache_handler
#include <messenger.h>
    use mod_kinds,          only: rk, ik
    use mod_constants,      only: NFACES, INTERIOR, CHIMERA, BOUNDARY, DIAG, NO_PROC,   &
                                  ME, NEIGHBOR, HALF, ONE,                              &
                                  XI_MIN, XI_MAX, ETA_MIN, ETA_MAX, ZETA_MIN, ZETA_MAX
    use mod_DNAD_tools,     only: face_compute_seed, element_compute_seed
    use mod_interpolate,    only: interpolate_face_autodiff, interpolate_element_autodiff
    use mod_chidg_mpi,      only: IRANK
    use DNAD_D

    use type_chidg_cache,   only: chidg_cache_t
    use type_chidg_worker,  only: chidg_worker_t
    use type_equation_set,  only: equation_set_t
    use type_bc,            only: bc_t

    implicit none



    !>  An object for handling cache operations. Particularly, updating the cache contents.
    !!
    !!  The problem solved here is this. The cache is used in operator_t's to pull data
    !!  computed at quadrature nodes. The cache also requires bc_operators's to precompute
    !!  the boundary condition solution as an external state and also to compute the BR2
    !!  diffusion lifting operators. This introduced a pesky circular dependency.
    !!
    !!  The problem was solved by introducing this cache_handler object. This separates the
    !!  cache behavior from the cache storage. The operator_t's need the cache storage. 
    !!  They don't need to know how the data got there.
    !!
    !!  So this higher-level interface sits outside of the hierarchy that caused the circular
    !!  dependency to handle the cache behavior, such as how it gets updated.
    !!
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    type, public :: cache_handler_t



    contains


        procedure   :: update   ! Resize/Update the cache fields


        procedure, private  :: update_auxiliary_fields
        procedure, private  :: update_primary_fields


        procedure, private  :: update_auxiliary_interior
        procedure, private  :: update_auxiliary_exterior
        procedure, private  :: update_auxiliary_element
        procedure, private  :: update_auxiliary_bc

        procedure, private  :: update_primary_interior
        procedure, private  :: update_primary_exterior
        procedure, private  :: update_primary_element
        procedure, private  :: update_primary_bc
        procedure, private  :: update_primary_lift

        procedure, private  :: update_model_interior
        procedure, private  :: update_model_exterior
        procedure, private  :: update_model_element
        procedure, private  :: update_model_bc

        procedure, private  :: update_lift_faces_internal
        procedure, private  :: update_lift_faces_external

    end type cache_handler_t
    !****************************************************************************************





contains


    !>  Resize chidg_cache in worker, update cache components.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik) :: idomain_l, ielement_l, iface
        logical     :: compute_gradients


        !
        ! Resize cache
        !
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        call worker%cache%resize(worker%mesh,worker%prop,idomain_l,ielement_l,differentiate)



        !
        ! Determine if we want to update gradient terms in the cache
        !
        compute_gradients = (allocated(equation_set(idomain_l)%volume_diffusive_operator) .or. &
                             allocated(equation_set(idomain_l)%boundary_diffusive_operator) )



        !
        ! Update fields
        !
        call self%update_auxiliary_fields(worker,equation_set,bc,differentiate)
        call self%update_primary_fields(  worker,equation_set,bc,differentiate,compute_gradients)



        !
        ! Compute f(Q-) models. Interior, Exterior, BC, Element
        !
        do iface = 1,NFACES

            ! Update worker face index
            call worker%set_face(iface)

            ! Update face interior/exterior/bc states.
            call self%update_model_interior(worker,equation_set,bc,differentiate,model_type='f(Q-)')
            call self%update_model_exterior(worker,equation_set,bc,differentiate,model_type='f(Q-)')


            call self%update_primary_bc(worker,equation_set,bc,differentiate)
            call self%update_model_bc(  worker,equation_set,bc,differentiate,model_type='f(Q-)')


            call self%update_model_interior(worker,equation_set,bc,differentiate,model_type='f(Q-,Q+)')
            call self%update_model_exterior(worker,equation_set,bc,differentiate,model_type='f(Q-,Q+)')
            call self%update_model_bc(      worker,equation_set,bc,differentiate,model_type='f(Q-,Q+)')

        end do !iface

        call self%update_model_element(worker,equation_set,bc,differentiate,model_type='f(Q-)')
        call self%update_model_element(worker,equation_set,bc,differentiate,model_type='f(Q-,Q+)')





        !
        ! Compute f(Q-,Q+), f(Grad(Q) models. Interior, Exterior, BC, Element
        !
        if (compute_gradients) then

            !
            ! Update lifting operators for second-order pde's
            !
            call self%update_primary_lift(worker,equation_set,bc,differentiate)


            !
            ! Loop through faces and cache 'internal', 'external' interpolated states
            !
            do iface = 1,NFACES

                ! Update worker face index
                call worker%set_face(iface)

                ! Update face interior/exterior/bc states.
                call self%update_model_interior(worker,equation_set,bc,differentiate,model_type='f(Grad(Q))')
                call self%update_model_exterior(worker,equation_set,bc,differentiate,model_type='f(Grad(Q))')
                call self%update_model_bc(      worker,equation_set,bc,differentiate,model_type='f(Grad(Q))')

            end do !iface

            
            !
            ! Update model 'element' cache entries
            !
            call self%update_model_element(worker,equation_set,bc,differentiate,model_type='f(Grad(Q))')


        end if ! compute_gradients

    end subroutine update
    !****************************************************************************************







    !>  Update the cache entries for the primary fields.
    !!
    !!  Activities:
    !!      #1: Loop through faces, update 'face interior', 'face exterior' caches for 
    !!          'value' and 'gradients'
    !!      #2: Update the 'element' cache for 'value' and 'gradients'
    !!      #3: Update the lifting operators for all cache components
    !!          (interior, exterior, element)
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_fields(self,worker,equation_set,bc,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idomain_l, ielement_l, iface, &
                                                       idepend, ieqn, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 


        !
        ! Loop through faces and cache 'internal', 'external' interpolated states
        !
        do iface = 1,NFACES

            ! Update worker face index
            call worker%set_face(iface)


            ! Update face interior/exterior/bc states.
            call self%update_primary_interior(worker,equation_set,bc,differentiate,compute_gradients)
            call self%update_primary_exterior(worker,equation_set,bc,differentiate,compute_gradients)


        end do !iface


        !
        ! Update 'element' cache
        !
        call self%update_primary_element(worker,equation_set,bc,differentiate,compute_gradients)


    end subroutine update_primary_fields
    !****************************************************************************************










    !>  Update the cache entries for the auxiliary fields.
    !!
    !!  Activities:
    !!      #1: Loop through faces, update 'face interior', 'face exterior' caches for 
    !!          'value' and 'gradients'
    !!      #2: Update the 'element' cache for 'value' and 'gradients'
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/7/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_fields(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik)                                 :: idomain_l, ielement_l, iface, idepend, &
                                                       ieqn, ifield, iaux_field, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 


        !
        ! Loop through faces and cache internal, external interpolated states
        !
        do iface = 1,NFACES

            ! Update worker face index
            call worker%set_face(iface)


            ! Update face interior/exterior states.
            call self%update_auxiliary_interior(worker,equation_set,bc,differentiate)
            call self%update_auxiliary_exterior(worker,equation_set,bc,differentiate)
            call self%update_auxiliary_bc(      worker,equation_set,bc,differentiate)


        end do !iface



        !
        ! Update cache 'element' data
        !
        call self%update_auxiliary_element(worker,equation_set,bc,differentiate)



    end subroutine update_auxiliary_fields
    !****************************************************************************************








!    !>  Update the cache entries for model fields.
!    !!
!    !!  Executes the model functions directly from the equation set. This allows
!    !!  the model to handle what it wants to cache.
!    !!
!    !!  NOTE: This only provides model 'value' cache entries. Model gradients are not
!    !!  currently implemented.
!    !!
!    !!  @author Nathan A. Wukie (AFRL)
!    !!  @date   9/7/2016
!    !!
!    !----------------------------------------------------------------------------------------
!    subroutine update_model_fields(self,worker,equation_set,bc,differentiate,model_type)
!        class(cache_handler_t),     intent(inout)   :: self
!        type(chidg_worker_t),       intent(inout)   :: worker
!        type(equation_set_t),       intent(inout)   :: equation_set(:)
!        type(bc_t),                 intent(inout)   :: bc(:)
!        logical,                    intent(in)      :: differentiate
!        character(*),               intent(in)      :: model_type
!
!        logical                     :: diff_none, diff_interior, diff_exterior, compute_model
!        integer(ik)                 :: iface, imodel, idomain_l, ielement_l, idepend, idiff, &
!                                       ipattern, ndepend
!        integer(ik),    allocatable :: compute_pattern(:)
!        character(:),   allocatable :: dependency
!
!
!        idomain_l  = worker%element_info%idomain_l 
!        ielement_l = worker%element_info%ielement_l 
!
!
!
!        !
!        ! Loop through faces and cache internal, external interpolated states
!        !
!        do iface = 1,NFACES
!
!            ! Update worker face index
!            call worker%set_face(iface)
!
!            ! Update model 'face interior' 'face exterior' cache entries for 'value'
!            call self%update_model_interior(worker,equation_set,bc,differentiate,model_type)
!            call self%update_model_exterior(worker,equation_set,bc,differentiate,model_type)
!
!        end do !iface
!
!
!        
!        !
!        ! Update 'element' cache entries
!        !
!        call self%update_model_element(worker,equation_set,bc,differentiate,model_type)
!
!
!
!    end subroutine update_model_fields
!    !****************************************************************************************









    !>  Update the primary field 'element' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_element(self,worker,equation_set,bc,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, &
                                                       iface, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Element primary fields volume 'value' cache. Only depends on interior element
        !
        if (differentiate) then
            idiff = DIAG
        else
            idiff = 0
        end if


        !
        ! Compute Value/Gradients
        !
        idepend = 1
        do ieqn = 1,worker%mesh(idomain_l)%neqns

            worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff)
            worker%function_info%idepend = idepend

            value_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ieqn,worker%itime,'value')
            grad1_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ieqn,worker%itime,'grad1')
            grad2_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ieqn,worker%itime,'grad2')
            grad3_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%q,worker%element_info,worker%function_info,ieqn,worker%itime,'grad3')

            field = worker%prop(idomain_l)%get_primary_field_name(ieqn)
            call worker%cache%set_data(field,'element',value_gq,'value',0,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad1_gq,'gradient',1,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad2_gq,'gradient',2,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad3_gq,'gradient',3,worker%function_info%seed)

        end do !ieqn



    end subroutine update_primary_element
    !*****************************************************************************************










    !>  Update the primary field 'face interior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_interior(self,worker,equation_set,bc,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, &
                                                       iface, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface

        !
        ! Face interior state. 'values' only depends on interior element.
        !
        idepend = 1


        !
        ! Set differentiation indicator
        !
        if (differentiate) then
            idiff = DIAG
        else
            idiff = 0
        end if


        !
        ! Compute Values
        !
        do ieqn = 1,worker%mesh(idomain_l)%neqns

            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
            worker%function_info%idepend = idepend
            worker%function_info%idiff   = idiff

            ! Interpolate modes to nodes
            value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'value',ME)
            grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'grad1',ME)
            grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'grad2',ME)
            grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'grad3',ME)

            ! Store gq data in cache
            field = worker%prop(idomain_l)%get_primary_field_name(ieqn)
            call worker%cache%set_data(field,'face interior',value_gq,'value',   0,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

        end do !ieqn




    end subroutine update_primary_interior
    !*****************************************************************************************










    !>  Update the primary field 'face exterior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_exterior(self,worker,equation_set,bc,differentiate,compute_gradients)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        logical,                    intent(in)      :: compute_gradients

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, &
                                                       iface, BC_ID, BC_face, ndepend, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Set differentiation indicator
        !
        if (differentiate) then
            idiff = iface
        else
            idiff = 0
        end if


        ! 
        ! Compute the number of exterior element dependencies for face exterior state
        !
        ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)



        !
        ! Face exterior state. Value
        !
        if ( (worker%face_type() == INTERIOR) .or. (worker%face_type() == CHIMERA) ) then
            
            do ieqn = 1,worker%mesh(idomain_l)%neqns
                field = worker%prop(idomain_l)%get_primary_field_name(ieqn)
                do idepend = 1,ndepend

                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                    worker%function_info%idepend = idepend

                    value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'value',NEIGHBOR)
                    grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'grad1',NEIGHBOR)
                    grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'grad2',NEIGHBOR)
                    grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%q,worker%face_info(),worker%function_info,ieqn,worker%itime,'grad3',NEIGHBOR)


                    call worker%cache%set_data(field,'face exterior',value_gq,'value',   0,worker%function_info%seed,iface)
                    call worker%cache%set_data(field,'face exterior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
                    call worker%cache%set_data(field,'face exterior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
                    call worker%cache%set_data(field,'face exterior',grad3_gq,'gradient',3,worker%function_info%seed,iface)


                end do !idepend
            end do !ieqn

        end if



    end subroutine update_primary_exterior
    !*****************************************************************************************








    !>  Update the primary field BOUNDARY state functions. These are placed in the 
    !!  'face exterior' cache entry.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_bc(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik)                 :: idepend, ieqn, idomain_l, ielement_l, iface, ndepend, &
                                       istate, bc_ID, patch_ID, patch_face
        character(:),   allocatable :: field


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Face bc(exterior) state
        !
        if ( (worker%face_type() == BOUNDARY)  ) then
            
            bc_ID      = worker%mesh(idomain_l)%faces(ielement_l,iface)%bc_ID
            patch_ID   = worker%mesh(idomain_l)%faces(ielement_l,iface)%patch_ID
            patch_face = worker%mesh(idomain_l)%faces(ielement_l,iface)%patch_face

            ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)
            do istate = 1,size(bc(bc_ID)%bc_state)
                do idepend = 1,ndepend

                    ! Get coupled bc element to linearize against.
                    if (differentiate) then
                        worker%function_info%seed%idomain_g  = bc(bc_ID)%bc_patch(patch_ID)%idomain_g_coupled(patch_face)%at(idepend)
                        worker%function_info%seed%idomain_l  = bc(bc_ID)%bc_patch(patch_ID)%idomain_l_coupled(patch_face)%at(idepend)
                        worker%function_info%seed%ielement_g = bc(bc_ID)%bc_patch(patch_ID)%ielement_g_coupled(patch_face)%at(idepend)
                        worker%function_info%seed%ielement_l = bc(bc_ID)%bc_patch(patch_ID)%ielement_l_coupled(patch_face)%at(idepend)
                        worker%function_info%seed%iproc      = bc(bc_ID)%bc_patch(patch_ID)%proc_coupled(patch_face)%at(idepend)
                    else
                        worker%function_info%seed%idomain_g  = 0
                        worker%function_info%seed%idomain_l  = 0
                        worker%function_info%seed%ielement_g = 0
                        worker%function_info%seed%ielement_l = 0
                        worker%function_info%seed%iproc      = NO_PROC
                    end if

                    call bc(bc_ID)%bc_state(istate)%state%compute_bc_state(worker,equation_set(idomain_l)%prop)

                end do !idepend
            end do !istate


        end if



    end subroutine update_primary_bc
    !*****************************************************************************************











    !>  Update the primary field lift functions for diffusion.
    !!
    !!  This only gets computed if there are diffusive operators allocated to the 
    !!  equation set. If not, then there is no need for the lifting operators and they
    !!  are not computed.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_primary_lift(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik) :: idomain_l


        idomain_l  = worker%element_info%idomain_l 

        !
        ! Update lifting terms for gradients if diffusive operators are present
        !
        if (allocated(equation_set(idomain_l)%volume_diffusive_operator) .or. &
            allocated(equation_set(idomain_l)%boundary_diffusive_operator)) then

            call self%update_lift_faces_internal(worker,equation_set,bc,differentiate)
            call self%update_lift_faces_external(worker,equation_set,bc,differentiate)

        end if

    end subroutine update_primary_lift
    !*****************************************************************************************











    !>  Update the auxiliary field 'element' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_element(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, iface, &
                                                       idiff, iaux_field, ifield
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Element primary fields volume 'value' cache. Only depends on interior element
        !
        if (differentiate) then
            idiff = DIAG
        else
            idiff = 0
        end if

        idepend = 0 ! no linearization
        do ifield = 1,worker%prop(idomain_l)%nauxiliary_fields()

            !
            ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
            !
            field      = worker%prop(idomain_l)%get_auxiliary_field_name(ifield)
            iaux_field = worker%solverdata%get_auxiliary_field_index(field)

            ! Set seed
            worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff)
            worker%function_info%idepend = idepend
            worker%function_info%idiff   = idiff

            ! Interpolate modes to nodes
            ieqn = 1    !implicitly assuming only 1 equation in the auxiliary field chidgVector
            value_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ieqn,worker%itime,'value')
            grad1_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ieqn,worker%itime,'grad1')
            grad2_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ieqn,worker%itime,'grad2')
            grad3_gq = interpolate_element_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%element_info,worker%function_info,ieqn,worker%itime,'grad3')

            ! Store gq data in cache
            call worker%cache%set_data(field,'element',value_gq,'value',   0,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad1_gq,'gradient',1,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad2_gq,'gradient',2,worker%function_info%seed)
            call worker%cache%set_data(field,'element',grad3_gq,'gradient',3,worker%function_info%seed)

        end do !ieqn




    end subroutine update_auxiliary_element
    !*****************************************************************************************









    !>  Update the auxiliary field 'face interior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_interior(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, iface, &
                                                       iaux_field, ifield, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Set differentiation indicator
        !
        if (differentiate) then
            idiff = DIAG
        else
            idiff = 0
        end if



        !
        ! Face interior state. 
        !
        idepend = 0 ! no linearization
        do ifield = 1,worker%prop(idomain_l)%nauxiliary_fields()

            !
            ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
            !
            field      = worker%prop(idomain_l)%get_auxiliary_field_name(ifield)
            iaux_field = worker%solverdata%get_auxiliary_field_index(field)

            ! Set seed
            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
            worker%function_info%idepend = idepend
            worker%function_info%idiff   = idiff

            ! Interpolate modes to nodes
            ieqn = 1    !implicitly assuming only 1 equation in the auxiliary field chidgVector
            value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'value',ME)
            grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad1',ME)
            grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad2',ME)
            grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad3',ME)

            ! Store gq data in cache
            call worker%cache%set_data(field,'face interior',value_gq,'value',     0,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
            call worker%cache%set_data(field,'face interior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

        end do !ieqn



    end subroutine update_auxiliary_interior
    !*****************************************************************************************














    !>  Update the auxiliary field 'face exterior' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_exterior(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, iface, &
                                                       iaux_field, ifield, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Set differentiation indicator
        !
        if (differentiate) then
            idiff = DIAG
        else
            idiff = 0
        end if


        !
        ! Face exterior state. 
        !
        if ( (worker%face_type() == INTERIOR) .or. (worker%face_type() == CHIMERA) ) then

            idepend = 0 ! no linearization
            do ifield = 1,worker%prop(idomain_l)%nauxiliary_fields()

                !
                ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
                !
                field      = worker%prop(idomain_l)%get_auxiliary_field_name(ifield)
                iaux_field = worker%solverdata%get_auxiliary_field_index(field)

                ! Set seed
                worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                worker%function_info%idepend = idepend
                worker%function_info%idiff   = idiff

                ! Interpolate modes to nodes
                ieqn = 1    !implicitly assuming only 1 equation in the auxiliary field chidgVector
                value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'value',NEIGHBOR)
                grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad1',NEIGHBOR)
                grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad2',NEIGHBOR)
                grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad3',NEIGHBOR)

                ! Store gq data in cache
                call worker%cache%set_data(field,'face exterior',value_gq,'value',     0,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

            end do !ieqn

        end if



    end subroutine update_auxiliary_exterior
    !*****************************************************************************************










    !>  Update the auxiliary field bc(face exterior) cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  NOTE: This extrapolates information from the 'face interior' and stores in in the
    !!        'face exterior' cache. These are auxiliary fields so they don't exactly have
    !!        a definition outside the domain. An extrapolation is a reasonable assumption.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_auxiliary_bc(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik)                                 :: idepend, ieqn, idomain_l, ielement_l, iface, &
                                                       iaux_field, ifield, idiff
        character(:),   allocatable                 :: field
        type(AD_D),     allocatable, dimension(:)   :: value_gq, grad1_gq, grad2_gq, grad3_gq


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Set differentiation indicator
        !
        if (differentiate) then
            idiff = DIAG
        else
            idiff = 0
        end if



        !
        ! Face interior state. 
        !
        if ( (worker%face_type() == BOUNDARY) ) then

            idepend = 0 ! no linearization
            do ifield = 1,worker%prop(idomain_l)%nauxiliary_fields()

                !
                ! Try to find the auxiliary field in the solverdata_t container; where they are stored.
                !
                field      = worker%prop(idomain_l)%get_auxiliary_field_name(ifield)
                iaux_field = worker%solverdata%get_auxiliary_field_index(field)

                ! Set seed
                worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                worker%function_info%idepend = idepend
                worker%function_info%idiff   = idiff

                !
                ! Interpolate modes to nodes
                ieqn = 1    !implicitly assuming only 1 equation in the auxiliary field chidgVector
                value_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'value',ME)
                grad1_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad1',ME)
                grad2_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad2',ME)
                grad3_gq = interpolate_face_autodiff(worker%mesh,worker%solverdata%auxiliary_field(iaux_field),worker%face_info(),worker%function_info,ieqn,worker%itime,'grad3',ME)

                ! Store gq data in cache
                call worker%cache%set_data(field,'face exterior',value_gq,'value',   0,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad1_gq,'gradient',1,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad2_gq,'gradient',2,worker%function_info%seed,iface)
                call worker%cache%set_data(field,'face exterior',grad3_gq,'gradient',3,worker%function_info%seed,iface)

            end do !ieqn

        end if



    end subroutine update_auxiliary_bc
    !*****************************************************************************************








    !>  Update the model field 'element' cache entries.
    !!
    !!  Computes the 'value' and 'gradient' entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_model_element(self,worker,equation_set,bc,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        logical                     :: diff_none, diff_interior, diff_exterior, compute_model
        integer(ik)                 :: imodel, idomain_l, ielement_l, idepend, idiff, &
                                       ipattern, ndepend
        integer(ik),    allocatable :: compute_pattern(:)
        character(:),   allocatable :: dependency

        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 


        !
        ! Compute element model field. Potentially differentiated wrt exterior elements.
        !
        worker%interpolation_source = 'element'
        do imodel = 1,equation_set(idomain_l)%nmodels()

            !
            ! Get model dependency
            !
            dependency = equation_set(idomain_l)%models(imodel)%model%get_dependency()

            !
            ! Only execute models specified in incoming model_type
            !
            if (trim(dependency) == trim(model_type)) then

                !
                ! Determine pattern to compute functions. Depends on if we are differentiating 
                ! or not. These will be used to set idiff, indicating the differentiation
                ! direction.
                !
                if (differentiate) then
                    ! compute function, wrt (all exterior)/interior states
                    if (dependency == 'f(Q-)') then
                        compute_pattern = [DIAG]
                    else if ( (dependency == 'f(Q-,Q+)') .or. &
                              (dependency == 'f(Grad(Q))') ) then
                        compute_pattern = [1,2,3,4,5,6,DIAG]
                    else
                        call chidg_signal(FATAL,"cache_handler%update_model_element: Invalid model dependency string.")
                    end if
                else
                    ! compute function, but do not differentiate
                    compute_pattern = [0]
                end if




                !
                ! Execute compute pattern
                !
                do ipattern = 1,size(compute_pattern)

                
                    !
                    ! get differentiation indicator
                    !
                    idiff = compute_pattern(ipattern)

                    diff_none     = (idiff == 0)
                    diff_interior = (idiff == DIAG)
                    diff_exterior = ( (idiff == 1) .or. (idiff == 2) .or. &
                                      (idiff == 3) .or. (idiff == 4) .or. &
                                      (idiff == 5) .or. (idiff == 6) )



                    if (diff_interior .or. diff_none) then
                        compute_model = .true.
                    else if (diff_exterior) then
                        compute_model = ( (worker%mesh(idomain_l)%faces(ielement_l,idiff)%ftype == INTERIOR) .or. &
                                          (worker%mesh(idomain_l)%faces(ielement_l,idiff)%ftype == CHIMERA) )
                    end if



                    if (compute_model) then

                        if (diff_none .or. diff_interior) then
                            ndepend = 1
                        else
                            call worker%set_face(idiff)
                            ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)
                        end if

                        do idepend = 1,ndepend
                            worker%function_info%seed    = element_compute_seed(worker%mesh,idomain_l,ielement_l,idepend,idiff)
                            worker%function_info%idepend = idepend

                            call equation_set(idomain_l)%models(imodel)%model%compute(worker)
                        end do !idepend
                    end if !compute

                end do !ipattern

            end if ! select model type
        end do !imodel


    end subroutine update_model_element
    !*****************************************************************************************










    !>  Update the model field 'value', 'face interior' cache entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_model_interior(self,worker,equation_set,bc,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        logical                     :: exterior_coupling, selected_model
        integer(ik)                 :: idepend, imodel, idomain_l, ielement_l, &
                                       iface, idiff, ndepend
        integer(ik),    allocatable :: compute_pattern(:)
        character(:),   allocatable :: field, model_dependency, mode
        type(AD_D),     allocatable :: value_gq(:)


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Update models for 'face interior'. Differentiated wrt interior.
        !
        idepend = 1
        worker%interpolation_source = 'face interior'
        do imodel = 1,equation_set(idomain_l)%nmodels()

            !
            ! Compute if model dependency matches specified model type in the 
            ! function interface.
            !
            model_dependency = equation_set(idomain_l)%models(imodel)%model%get_dependency()
            selected_model = (trim(model_type) == trim(model_dependency))

            if (selected_model) then

                !
                ! Set differentiation indicator
                !
                if (differentiate) then
                    idiff = DIAG
                else
                    idiff = 0 
                end if


                worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                worker%function_info%idepend = idepend
                worker%function_info%idiff   = idiff

                call equation_set(idomain_l)%models(imodel)%model%compute(worker)

            end if !select model

        end do !imodel




        !
        ! Update models for 'face interior'. Differentiated wrt exterior.
        !
        worker%interpolation_source = 'face interior'
        if ( (worker%face_type() == INTERIOR) .or. &
             (worker%face_type() == CHIMERA) ) then

            if (differentiate) then

                do imodel = 1,equation_set(idomain_l)%nmodels()

                    !
                    ! Get model dependency 
                    !
                    model_dependency = equation_set(idomain_l)%models(imodel)%model%get_dependency()

                    selected_model    = (trim(model_type) == trim(model_dependency))
                    exterior_coupling = (model_dependency == 'f(Q-,Q+)') .or. (model_dependency == 'f(Grad(Q))')

                    if ( selected_model .and. exterior_coupling ) then

                        !
                        ! Set differentiation indicator
                        !
                        idiff = iface

                        ! 
                        ! Compute the number of exterior element dependencies
                        !
                        ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)

                        !
                        ! Loop through external dependencies and compute model
                        !
                        do idepend = 1,ndepend
                            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                            worker%function_info%idepend = idepend
                            worker%function_info%idiff   = idiff

                            call equation_set(idomain_l)%models(imodel)%model%compute(worker)
                        end do !idepend

                    end if ! select model


                end do !imodel

            end if !differentiate
        end if ! INTERIOR or CHIMERA



    end subroutine update_model_interior
    !*****************************************************************************************











    !>  Update the model field 'value', 'face exterior' cache entries.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine update_model_exterior(self,worker,equation_set,bc,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        integer(ik)                 :: idepend, imodel, idomain_l, ielement_l, iface, &
                                       bc_ID, patch_ID, patch_face, ndepend, idiff
        character(:),   allocatable :: field, model_dependency
        logical                     :: selected_model


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface



        !
        ! Face exterior state: interior neighbors and chimera
        !
        worker%interpolation_source = 'face exterior'
        if ( (worker%face_type() == INTERIOR) .or. (worker%face_type() == CHIMERA) ) then

            !
            ! Set differentiation indicator. Differentiate 'face exterior' wrt EXTERIOR elements
            !
            if (differentiate) then
                idiff = iface
            else
                idiff = 0
            end if
            
            ! 
            ! Compute the number of exterior element dependencies for face exterior state
            !
            ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)
            do imodel = 1,equation_set(idomain_l)%nmodels()

                !
                ! Get model dependency 
                !
                model_dependency = equation_set(idomain_l)%models(imodel)%model%get_dependency()
                selected_model   = (trim(model_type) == trim(model_dependency))

                if (selected_model) then
                    do idepend = 1,ndepend

                        worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                        worker%function_info%idepend = idepend

                        call equation_set(idomain_l)%models(imodel)%model%compute(worker)

                    end do !idepend
                end if !select model

            end do !imodel


            !
            ! Set differentiation indicator. Differentiate 'face exterior' wrt INTERIOR element
            ! Only need to compute if differentiating
            !
            if (differentiate) then

                idiff = DIAG
            
                ! 
                ! Compute the number of exterior element dependencies for face exterior state
                !
                ndepend = 1
                do imodel = 1,equation_set(idomain_l)%nmodels()

                    !
                    ! Get model dependency 
                    !
                    model_dependency = equation_set(idomain_l)%models(imodel)%model%get_dependency()
                    selected_model   = (trim(model_type) == trim(model_dependency))

                    if (selected_model) then
                        do idepend = 1,ndepend

                            worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                            worker%function_info%idepend = idepend

                            call equation_set(idomain_l)%models(imodel)%model%compute(worker)

                        end do !idepend
                    end if !select model

                end do !imodel

            end if


        end if ! worker%face_type()

    end subroutine update_model_exterior
    !*****************************************************************************************







    !>  Update the model field BOUNDARY state functions. These are placed in the 
    !!  'face exterior' cache entry.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   3/9/2017
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_model_bc(self,worker,equation_set,bc,differentiate,model_type)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate
        character(*),               intent(in)      :: model_type

        integer(ik)                 :: idepend, ieqn, idomain_l, ielement_l, iface, ndepend, &
                                       istate, bc_ID, patch_ID, patch_face, imodel
        character(:),   allocatable :: field, model_dependency
        logical                     :: selected_model


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface



        !
        ! Face exterior state: boundaries
        !
        worker%interpolation_source = 'face exterior'
        if ( (worker%face_type() == BOUNDARY) ) then

            ! 
            ! Compute the number of exterior element dependencies for face exterior state
            !
            ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)

            bc_ID      = worker%mesh(idomain_l)%faces(ielement_l,iface)%bc_ID
            patch_ID   = worker%mesh(idomain_l)%faces(ielement_l,iface)%patch_ID
            patch_face = worker%mesh(idomain_l)%faces(ielement_l,iface)%patch_face

            do imodel = 1,equation_set(idomain_l)%nmodels()

                !
                ! Get model dependency 
                !
                model_dependency = equation_set(idomain_l)%models(imodel)%model%get_dependency()
                selected_model   = (trim(model_type) == trim(model_dependency))

                if (selected_model) then
                    do idepend = 1,ndepend

                        if (differentiate) then
                            ! Get coupled bc element to differentiate wrt
                            worker%function_info%seed%idomain_g  = bc(bc_ID)%bc_patch(patch_ID)%idomain_g_coupled(patch_face)%at(idepend)
                            worker%function_info%seed%idomain_l  = bc(bc_ID)%bc_patch(patch_ID)%idomain_l_coupled(patch_face)%at(idepend)
                            worker%function_info%seed%ielement_g = bc(bc_ID)%bc_patch(patch_ID)%ielement_g_coupled(patch_face)%at(idepend)
                            worker%function_info%seed%ielement_l = bc(bc_ID)%bc_patch(patch_ID)%ielement_l_coupled(patch_face)%at(idepend)
                            worker%function_info%seed%iproc      = bc(bc_ID)%bc_patch(patch_ID)%proc_coupled(patch_face)%at(idepend)

                        else
                            ! Set no differentiation
                            worker%function_info%seed%idomain_g  = 0
                            worker%function_info%seed%idomain_l  = 0
                            worker%function_info%seed%ielement_g = 0
                            worker%function_info%seed%ielement_l = 0
                            worker%function_info%seed%iproc      = NO_PROC
                        end if

                        call equation_set(idomain_l)%models(imodel)%model%compute(worker)

                    end do !idepend
                end if !select model

            end do !imodel


        end if ! worker%face_type()





    end subroutine update_model_bc
    !*****************************************************************************************















    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !-----------------------------------------------------------------------------------------
    subroutine update_lift_faces_internal(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        character(:),   allocatable :: field
        integer(ik)                 :: idomain_l, ielement_l, iface, idepend, &
                                       ndepend, BC_ID, BC_face, ieqn, idiff

        type(AD_D), allocatable, dimension(:), save   ::    &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            rhs_x,          rhs_y,          rhs_z,          &
            lift_modes_x,   lift_modes_y,   lift_modes_z,   &
            lift_gq_face_x, lift_gq_face_y, lift_gq_face_z, &
            lift_gq_vol_x,  lift_gq_vol_y,  lift_gq_vol_z



        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 





        !
        ! For each face, compute the lifting operators associated with each equation for the 
        ! internal and external states and also their linearization.
        !
        do iface = 1,NFACES


            !
            ! Update worker face index
            !
            call worker%set_face(iface)



            associate ( weights          => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%weights(:,iface),      &
                        val_face_trans   => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val_trans(:,:,iface),  &
                        val_face         => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val(:,:,iface),        &
                        val_vol          => worker%mesh(idomain_l)%elems(ielement_l)%gq%vol%val,                    &
                        invmass          => worker%mesh(idomain_l)%elems(ielement_l)%invmass,                       &
                        br2_face         => worker%mesh(idomain_l)%faces(ielement_l,iface)%br2_face,                &
                        br2_vol          => worker%mesh(idomain_l)%faces(ielement_l,iface)%br2_vol)





            do ieqn = 1,worker%mesh(idomain_l)%neqns

                !
                ! Get field
                !
                field = worker%prop(idomain_l)%get_primary_field_name(ieqn)



                !
                ! Compute Interior lift, differentiated wrt Interior
                !

                ! Set differentiation indicator
                if (differentiate) then
                    idiff = DIAG
                else
                    idiff = 0
                end if

                ndepend = 1
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                    worker%function_info%idepend = idepend


                    ! Get interior/exterior state
                    var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
                    var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)

                    ! Difference
                    var_diff = HALF*(var_p - var_m) 

                    ! Multiply by weights
                    var_diff_weighted = var_diff * weights

                    ! Multiply by normal. Note: normal is scaled by face jacobian.
                    var_diff_x = var_diff_weighted * worker%normal(1)
                    var_diff_y = var_diff_weighted * worker%normal(2)
                    var_diff_z = var_diff_weighted * worker%normal(3)


                    !
                    ! Standard Approach breaks the process up into several steps:
                    !   1: Project onto basis
                    !   2: Local solve for lift modes in element basis
                    !   3: Interpolate lift modes to face/volume quadrature nodes
                    !
                    ! Project onto basis
!                    rhs_x = matmul(val_face_trans,var_diff_x)
!                    rhs_y = matmul(val_face_trans,var_diff_y)
!                    rhs_z = matmul(val_face_trans,var_diff_z)
! 
!                    ! Local solve for lift modes in element basis
!                    lift_modes_x = matmul(invmass,rhs_x)
!                    lift_modes_y = matmul(invmass,rhs_y)
!                    lift_modes_z = matmul(invmass,rhs_z)
! 
!                    ! Evaluate lift modes at face quadrature nodes
!                    lift_gq_face_x = matmul(val_face,lift_modes_x)
!                    lift_gq_face_y = matmul(val_face,lift_modes_y)
!                    lift_gq_face_z = matmul(val_face,lift_modes_z)

                    !
                    ! Improved approach creates a single matrix that performs the
                    ! three steps in one MV multiply:
                    !
                    !   br2_face = [val_face][invmass][val_face_trans]
                    !   br2_vol  = [val_vol ][invmass][val_face_trans]
                    !
                    lift_gq_face_x = matmul(br2_face,var_diff_x)
                    lift_gq_face_y = matmul(br2_face,var_diff_y)
                    lift_gq_face_z = matmul(br2_face,var_diff_z)

                    
                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_gq_face_x, 'lift face', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_face_y, 'lift face', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_face_z, 'lift face', 3, worker%function_info%seed, iface)


!                    ! Evaluate lift modes at volume quadrature nodes
!                    lift_gq_vol_x = matmul(val_vol,lift_modes_x)
!                    lift_gq_vol_y = matmul(val_vol,lift_modes_y)
!                    lift_gq_vol_z = matmul(val_vol,lift_modes_z)

                    lift_gq_vol_x = matmul(br2_vol,var_diff_x)
                    lift_gq_vol_y = matmul(br2_vol,var_diff_y)
                    lift_gq_vol_z = matmul(br2_vol,var_diff_z)

                    
                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_gq_vol_x, 'lift element', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_vol_y, 'lift element', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_vol_z, 'lift element', 3, worker%function_info%seed, iface)



                end do !idepend







                !
                ! Compute Interior lift, differentiated wrt Exterior
                !

                ! Set differentiation indicator
                if (differentiate) then
                    idiff = iface
                else
                    idiff = 0
                end if
                ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                    worker%function_info%idepend = idepend


                    ! Get interior/exterior state
                    var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
                    var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)

                    ! Difference
                    var_diff = HALF*(var_p - var_m) 

                    ! Multiply by weights
                    var_diff_weighted = var_diff * weights

                    ! Multiply by normal. Note: normal is scaled by face jacobian.
                    var_diff_x = var_diff_weighted * worker%normal(1)
                    var_diff_y = var_diff_weighted * worker%normal(2)
                    var_diff_z = var_diff_weighted * worker%normal(3)

!                    ! Project onto basis
!                    rhs_x = matmul(val_face_trans,var_diff_x)
!                    rhs_y = matmul(val_face_trans,var_diff_y)
!                    rhs_z = matmul(val_face_trans,var_diff_z)
!
!                    ! Local solve for lift modes in element basis
!                    lift_modes_x = matmul(invmass,rhs_x)
!                    lift_modes_y = matmul(invmass,rhs_y)
!                    lift_modes_z = matmul(invmass,rhs_z)


                    ! Evaluate lift modes at face quadrature nodes
!                    lift_gq_face_x = matmul(val_face,lift_modes_x)
!                    lift_gq_face_y = matmul(val_face,lift_modes_y)
!                    lift_gq_face_z = matmul(val_face,lift_modes_z)
                    lift_gq_face_x = matmul(br2_face,var_diff_x)
                    lift_gq_face_y = matmul(br2_face,var_diff_y)
                    lift_gq_face_z = matmul(br2_face,var_diff_z)
                    
                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_gq_face_x, 'lift face', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_face_y, 'lift face', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_face_z, 'lift face', 3, worker%function_info%seed, iface)


                    ! Evaluate lift modes at volume quadrature nodes
!                    lift_gq_vol_x = matmul(val_vol,lift_modes_x)
!                    lift_gq_vol_y = matmul(val_vol,lift_modes_y)
!                    lift_gq_vol_z = matmul(val_vol,lift_modes_z)
                    lift_gq_vol_x = matmul(br2_vol,var_diff_x)
                    lift_gq_vol_y = matmul(br2_vol,var_diff_y)
                    lift_gq_vol_z = matmul(br2_vol,var_diff_z)
                    
                    ! Store lift
                    call worker%cache%set_data(field,'face interior', lift_gq_vol_x, 'lift element', 1, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_vol_y, 'lift element', 2, worker%function_info%seed, iface)
                    call worker%cache%set_data(field,'face interior', lift_gq_vol_z, 'lift element', 3, worker%function_info%seed, iface)




                end do !idepend

            end do !ieqn


            end associate

        end do !iface


    end subroutine update_lift_faces_internal
    !*****************************************************************************************










    !>
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !----------------------------------------------------------------------------------------
    subroutine update_lift_faces_external(self,worker,equation_set,bc,differentiate)
        class(cache_handler_t),     intent(inout)   :: self
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik) :: idomain_l, ielement_l, iface, idepend, ieqn, &
                       ndepend, BC_ID, BC_face, idiff
        logical     :: boundary_face, interior_face, chimera_face


        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 


        !
        ! For each face, compute the lifting operators associated with each equation for the 
        ! internal and external states and also their linearization.
        !
        do iface = 1,NFACES

            !
            ! Update worker face index
            !
            call worker%set_face(iface)


            !
            ! Check if boundary or interior
            !
            boundary_face = (worker%face_type() == BOUNDARY)
            interior_face = (worker%face_type() == INTERIOR)
            chimera_face  = (worker%face_type() == CHIMERA )



            !
            ! Compute lift for each equation
            !
            do ieqn = 1,worker%mesh(idomain_l)%neqns


                !
                ! Compute External lift, differentiated wrt Interior
                !

                ! Set differentiation indicator
                if (differentiate) then
                    idiff = DIAG
                else
                    idiff = 0
                end if
                ndepend = 1
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                    worker%function_info%idepend = idepend


                    if (interior_face) then
                        call handle_external_lift__interior_face(worker,equation_set,bc,ieqn)
                    else if (boundary_face) then
                        call handle_external_lift__boundary_face(worker,equation_set,bc,ieqn)
                    else if (chimera_face) then
                        call handle_external_lift__chimera_face( worker,equation_set,bc,ieqn)
                    else
                        call chidg_signal(FATAL,"update_lift_faces_external: unsupported face type")
                    end if


                end do !idepend




                !
                ! Compute External lift, differentiated wrt Exterior
                !

                ! Set differentiation indicator
                if (differentiate) then
                    idiff = iface
                else
                    idiff = 0
                end if
                ndepend = get_ndepend_exterior(worker,equation_set,bc,differentiate)
                do idepend = 1,ndepend

                    ! Get Seed
                    worker%function_info%seed    = face_compute_seed(worker%mesh,idomain_l,ielement_l,iface,idepend,idiff)
                    worker%function_info%idepend = idepend

                    if (interior_face) then
                        call handle_external_lift__interior_face(worker,equation_set,bc,ieqn)
                    else if (boundary_face) then
                        call handle_external_lift__boundary_face(worker,equation_set,bc,ieqn)
                    else if (chimera_face) then
                        call handle_external_lift__chimera_face( worker,equation_set,bc,ieqn)
                    else
                        call chidg_signal(FATAL,"update_lift_faces_external: unsupported face type")
                    end if


                end do !idepend

            end do !ieqn



        end do !iface


    end subroutine update_lift_faces_external
    !*****************************************************************************************
















    !>  Handle computing lift for an external element, when the face is an interior face.
    !!
    !!  In this case, the external element exists and we can just use its data. This is 
    !!  not the case for a boundary condition face, and it is complicated further by a 
    !!  Chimera boundary face.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine handle_external_lift__interior_face(worker,equation_set,bc,ieqn)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        integer(ik),                intent(in)      :: ieqn

        integer(ik) :: idomain_l, ielement_l, iface, idomain_l_n, ielement_l_n, iface_n, iproc_n
        logical     :: boundary_face, interior_face, local_neighbor, remote_neighbor

        type(AD_D), allocatable, dimension(:)   ::          &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            rhs_x,          rhs_y,          rhs_z,          &
            lift_modes_x,   lift_modes_y,   lift_modes_z,   &
            lift_gq_face_x, lift_gq_face_y, lift_gq_face_z, &
            lift_gq_vol_x,  lift_gq_vol_y,  lift_gq_vol_z

        character(:),   allocatable                 :: field
        real(rk),       allocatable, dimension(:)   :: normx, normy, normz, weights
        real(rk),       allocatable, dimension(:,:) :: val_face_trans, val_face, val_vol, &
                                                       invmass, br2_face


        !
        ! Interior element
        ! 
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        !
        ! Neighbor element
        !
        idomain_l_n  = worker%mesh(idomain_l)%faces(ielement_l,iface)%ineighbor_domain_l
        ielement_l_n = worker%mesh(idomain_l)%faces(ielement_l,iface)%ineighbor_element_l
        iface_n      = worker%mesh(idomain_l)%faces(ielement_l,iface)%ineighbor_face
        iproc_n      = worker%mesh(idomain_l)%faces(ielement_l,iface)%ineighbor_proc

        local_neighbor  = (iproc_n == IRANK)
        remote_neighbor = (iproc_n /= IRANK)


        !
        ! Get field
        !
        field = worker%prop(idomain_l)%get_primary_field_name(ieqn)


        if ( local_neighbor ) then
            weights          = worker%mesh(idomain_l_n)%elems(ielement_l_n)%gq%face%weights(:,iface_n)
            val_face_trans   = worker%mesh(idomain_l_n)%elems(ielement_l_n)%gq%face%val_trans(:,:,iface_n)
            val_face         = worker%mesh(idomain_l_n)%elems(ielement_l_n)%gq%face%val(:,:,iface_n)
            val_vol          = worker%mesh(idomain_l_n)%elems(ielement_l_n)%gq%vol%val
            invmass          = worker%mesh(idomain_l_n)%elems(ielement_l_n)%invmass
            br2_face         = worker%mesh(idomain_l_n)%faces(ielement_l_n,iface_n)%br2_face


        else if ( remote_neighbor ) then
            ! User local element gq instance. Assumes same order of accuracy.
            weights          = worker%mesh(idomain_l)%elems(ielement_l)%gq%face%weights(:,iface_n)
            val_face_trans   = worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val_trans(:,:,iface_n)
            val_face         = worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val(:,:,iface_n)
            val_vol          = worker%mesh(idomain_l)%elems(ielement_l)%gq%vol%val
            invmass          = worker%mesh(idomain_l)%faces(ielement_l,iface)%neighbor_invmass
            br2_face         = worker%mesh(idomain_l)%faces(ielement_l,iface)%neighbor_br2_face


        end if



            ! Use reverse of interior element's normal vector
            normx = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,1)
            normy = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,2)
            normz = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,3)

            ! Get interior/exterior state
            var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
            var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)

            ! Difference. Relative to exterior element, so reversed
            var_diff = HALF*(var_m - var_p) 

            ! Multiply by weights
            var_diff_weighted = var_diff * weights

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            var_diff_x = var_diff_weighted * normx
            var_diff_y = var_diff_weighted * normy
            var_diff_z = var_diff_weighted * normz

            !
            ! Project onto basis
            !
!            ! Approach 1: start
!            rhs_x = matmul(val_face_trans,var_diff_x)
!            rhs_y = matmul(val_face_trans,var_diff_y)
!            rhs_z = matmul(val_face_trans,var_diff_z)
!
!            ! Local solve for lift modes in element basis
!            lift_modes_x = matmul(invmass,rhs_x)
!            lift_modes_y = matmul(invmass,rhs_y)
!            lift_modes_z = matmul(invmass,rhs_z)
!
!            ! Evaluate lift modes at quadrature nodes
!            lift_gq_face_x = matmul(val_face,lift_modes_x)
!            lift_gq_face_y = matmul(val_face,lift_modes_y)
!            lift_gq_face_z = matmul(val_face,lift_modes_z)
!            ! stop

            ! Approach 2: start
            lift_gq_face_x = matmul(br2_face,var_diff_x)
            lift_gq_face_y = matmul(br2_face,var_diff_y)
            lift_gq_face_z = matmul(br2_face,var_diff_z)
            ! stop
            
            ! Store lift
            call worker%cache%set_data(field,'face exterior', lift_gq_face_x, 'lift face', 1, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_gq_face_y, 'lift face', 2, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_gq_face_z, 'lift face', 3, worker%function_info%seed, iface)


    end subroutine handle_external_lift__interior_face
    !*****************************************************************************************














    !>  Handle computing lift for an external element, when the face is a boundary face.
    !!
    !!  In this case, the external element does NOT exist, so we use the interior element. 
    !!  This is kind of like assuming that a boundary element exists of equal size to 
    !!  the interior element.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine handle_external_lift__boundary_face(worker,equation_set,bc,ieqn)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        integer(ik),                intent(in)      :: ieqn

        integer(ik) :: idomain_l, ielement_l, iface, idomain_l_n, ielement_l_n, iface_n
        logical     :: boundary_face, interior_face

        type(AD_D), allocatable, dimension(:)   ::          &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            rhs_x,          rhs_y,          rhs_z,          &
            lift_modes_x,   lift_modes_y,   lift_modes_z,   &
            lift_gq_x,      lift_gq_y,      lift_gq_z

        character(:),   allocatable                 :: field
        real(rk),       allocatable, dimension(:)   :: normx, normy, normz


        !
        ! Interior element
        ! 
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface


        if (iface == XI_MIN) then
            iface_n = XI_MAX
        else if (iface == ETA_MIN) then
            iface_n = ETA_MAX
        else if (iface == ZETA_MIN) then
            iface_n = ZETA_MAX
        else if (iface == XI_MAX) then
            iface_n = XI_MIN
        else if (iface == ETA_MAX) then
            iface_n = ETA_MIN
        else if (iface == ZETA_MAX) then
            iface_n = ZETA_MIN
        end if


        !
        ! Get field
        !
        field = worker%prop(idomain_l)%get_primary_field_name(ieqn)



        !
        ! Neighbor element
        !
        idomain_l_n  = worker%mesh(idomain_l)%faces(ielement_l,iface)%ineighbor_domain_l
        ielement_l_n = worker%mesh(idomain_l)%faces(ielement_l,iface)%ineighbor_element_l


        associate ( weights          => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%weights(:,iface_n),        &
                    val_face_trans   => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val_trans(:,:,iface_n),    &
                    val_face         => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val(:,:,iface_n),          &
                    invmass          => worker%mesh(idomain_l)%elems(ielement_l)%invmass,                           &
                    br2_face         => worker%mesh(idomain_l)%faces(ielement_l,iface)%br2_face)

            ! Get normal vector. Use reverse of the normal vector from the interior element since no exterior element exists.
            normx = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,1)
            normy = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,2)
            normz = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,3)

            ! Get interior/exterior state
            var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
            var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)


            ! Difference. Relative to exterior element, so reversed
            var_diff = HALF*(var_m - var_p) 


            ! Multiply by weights
            var_diff_weighted = var_diff * weights


            ! Multiply by normal. Note: normal is scaled by face jacobian.
            var_diff_x = var_diff_weighted * normx
            var_diff_y = var_diff_weighted * normy
            var_diff_z = var_diff_weighted * normz


            !
            ! Project onto basis
            !
             ! Approach 1: start
!            rhs_x = matmul(val_face_trans,var_diff_x)
!            rhs_y = matmul(val_face_trans,var_diff_y)
!            rhs_z = matmul(val_face_trans,var_diff_z)
!
!
!            ! Local solve for lift modes in element basis
!            lift_modes_x = matmul(invmass,rhs_x)
!            lift_modes_y = matmul(invmass,rhs_y)
!            lift_modes_z = matmul(invmass,rhs_z)
!
!
!            ! Evaluate lift modes at quadrature nodes
!            lift_gq_x = matmul(val_face,lift_modes_x)
!            lift_gq_y = matmul(val_face,lift_modes_y)
!            lift_gq_z = matmul(val_face,lift_modes_z)
!            ! stop

            ! Approach 2: start
            lift_gq_x = matmul(br2_face,var_diff_x)
            lift_gq_y = matmul(br2_face,var_diff_y)
            lift_gq_z = matmul(br2_face,var_diff_z)
            ! stop
            

            ! Store lift
            call worker%cache%set_data(field,'face exterior', lift_gq_x, 'lift face', 1, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_gq_y, 'lift face', 2, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_gq_z, 'lift face', 3, worker%function_info%seed, iface)


        end associate






    end subroutine handle_external_lift__boundary_face
    !*****************************************************************************************












    !>  Handle computing lift for an external element, when the face is a Chimera face.
    !!
    !!  In this case, potentially multiple external elements exist, so we don't have just
    !!  a single exterior mass matrix.
    !!
    !!  @author Nathan A. Wukie (AFRL)
    !!  @date   9/14/2016
    !!
    !!
    !------------------------------------------------------------------------------------------
    subroutine handle_external_lift__chimera_face(worker,equation_set,bc,ieqn)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        integer(ik),                intent(in)      :: ieqn

        integer(ik) :: idomain_l, ielement_l, iface
        logical     :: boundary_face, interior_face

        type(AD_D), allocatable, dimension(:)   ::          &
            var_m, var_p, var_diff, var_diff_weighted,      &
            var_diff_x,     var_diff_y,     var_diff_z,     &
            rhs_x,          rhs_y,          rhs_z,          &
            lift_modes_x,   lift_modes_y,   lift_modes_z,   &
            lift_gq_face_x, lift_gq_face_y, lift_gq_face_z, &
            lift_gq_vol_x,  lift_gq_vol_y,  lift_gq_vol_z

        character(:),   allocatable                 :: field
        real(rk),       allocatable, dimension(:)   :: normx, normy, normz


        !
        ! Interior element
        ! 
        idomain_l  = worker%element_info%idomain_l 
        ielement_l = worker%element_info%ielement_l 
        iface      = worker%iface



        !
        ! Get field
        !
        field = worker%prop(idomain_l)%get_primary_field_name(ieqn)

        !
        ! Use components from receiver element since no single element exists to act 
        ! as the exterior element. This implicitly treats the diffusion terms as if 
        ! there were a reflected element like the receiver element that was acting as 
        ! the donor.
        !
        associate ( weights          => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%weights(:,iface),        &
                    val_face_trans   => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val_trans(:,:,iface),    &
                    val_face         => worker%mesh(idomain_l)%elems(ielement_l)%gq%face%val(:,:,iface),          &
                    val_vol          => worker%mesh(idomain_l)%elems(ielement_l)%gq%vol%val,                      &
                    invmass          => worker%mesh(idomain_l)%elems(ielement_l)%invmass,                         &
                    br2_face         => worker%mesh(idomain_l)%faces(ielement_l,iface)%br2_face)


            ! Use reversed normal vectors of receiver element
            normx = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,1)
            normy = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,2)
            normz = -worker%mesh(idomain_l)%faces(ielement_l,iface)%norm(:,3)

            ! Get interior/exterior state
            var_m = worker%cache%get_data(field,'face interior', 'value', 0, worker%function_info%seed, iface)
            var_p = worker%cache%get_data(field,'face exterior', 'value', 0, worker%function_info%seed, iface)

            ! Difference. Relative to exterior element, so reversed
            var_diff = HALF*(var_m - var_p) 

            ! Multiply by weights
            var_diff_weighted = var_diff * weights

            ! Multiply by normal. Note: normal is scaled by face jacobian.
            var_diff_x = var_diff_weighted * normx
            var_diff_y = var_diff_weighted * normy
            var_diff_z = var_diff_weighted * normz

            !
            ! Project onto basis
            !

!            ! Approach 1: start
!            rhs_x = matmul(val_face_trans,var_diff_x)
!            rhs_y = matmul(val_face_trans,var_diff_y)
!            rhs_z = matmul(val_face_trans,var_diff_z)
!
!            ! Local solve for lift modes in element basis
!            lift_modes_x = matmul(invmass,rhs_x)
!            lift_modes_y = matmul(invmass,rhs_y)
!            lift_modes_z = matmul(invmass,rhs_z)
!
!            ! Evaluate lift modes at quadrature nodes
!            lift_gq_face_x = matmul(val_face,lift_modes_x)
!            lift_gq_face_y = matmul(val_face,lift_modes_y)
!            lift_gq_face_z = matmul(val_face,lift_modes_z)
!            ! stop


            ! Approach 2: start
            lift_gq_face_x = matmul(br2_face,var_diff_x)
            lift_gq_face_y = matmul(br2_face,var_diff_y)
            lift_gq_face_z = matmul(br2_face,var_diff_z)
            ! stop 
            
            ! Store lift
            call worker%cache%set_data(field,'face exterior', lift_gq_face_x, 'lift face', 1, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_gq_face_y, 'lift face', 2, worker%function_info%seed, iface)
            call worker%cache%set_data(field,'face exterior', lift_gq_face_z, 'lift face', 3, worker%function_info%seed, iface)


        end associate






    end subroutine handle_external_lift__chimera_face
    !*****************************************************************************************







    !>  For a given state of the chidg_worker(idomain,ielement,iface), return the number
    !!  of exterior dependent elements.
    !!
    !!  @author Nathan A. Wukie
    !!  @date   12/7/2016
    !!
    !----------------------------------------------------------------------------------------
    function get_ndepend_exterior(worker,equation_set,bc,differentiate) result(ndepend)
        type(chidg_worker_t),       intent(inout)   :: worker
        type(equation_set_t),       intent(inout)   :: equation_set(:)
        type(bc_t),                 intent(inout)   :: bc(:)
        logical,                    intent(in)      :: differentiate

        integer(ik) :: ndepend, idomain_l, ielement_l, iface, &
                       ChiID, BC_ID, patch_ID, patch_face


        if (differentiate) then

            idomain_l  = worker%element_info%idomain_l 
            ielement_l = worker%element_info%ielement_l 
            iface      = worker%iface

            ! 
            ! Compute the number of exterior element dependencies for face exterior state
            !
            if ( worker%face_type() == INTERIOR ) then
                ndepend = 1
                
            else if ( worker%face_type() == CHIMERA ) then
                ChiID   = worker%mesh(idomain_l)%faces(ielement_l,iface)%ChiID
                ndepend = worker%mesh(idomain_l)%chimera%recv%data(ChiID)%ndonors()

            else if ( worker%face_type() == BOUNDARY ) then
                bc_ID      = worker%mesh(idomain_l)%faces(ielement_l,iface)%bc_ID
                patch_ID   = worker%mesh(idomain_l)%faces(ielement_l,iface)%patch_ID
                patch_face = worker%mesh(idomain_l)%faces(ielement_l,iface)%patch_face
                ndepend    = bc(bc_ID)%bc_patch(patch_ID)%ncoupled_elements(patch_face)

            end if

        else

            ndepend = 1

        end if

    end function get_ndepend_exterior
    !****************************************************************************************

























end module type_cache_handler
