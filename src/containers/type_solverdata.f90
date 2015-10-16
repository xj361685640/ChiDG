module type_solverdata
#include <messenger.h>
    use mod_kinds,              only: rk,ik
    use type_chidgVector,       only: chidgVector_t
    use type_chidgMatrix,       only: chidgMatrix_t
    use type_mesh,              only: mesh_t
    implicit none


    !> solver abstract type definition
    !!
    !!
    !!
    !!
    !!
    !-------------------------------------------------------------------------------------------------------
    type, public  :: solverdata_t
        !> Base solver data
        type(chidgVector_t)             :: q                        !< Solution vector
        type(chidgVector_t)             :: dq                       !< Change in solution vector
        type(chidgVector_t)             :: rhs                      !< Residual of the spatial scheme
        type(chidgMatrix_t)             :: lhs                      !< Linearization of the spatial scheme

        !real(rk), allocatable           :: dt(:)                    !< Element-local time step

        logical                         :: solverInitialized = .false.




        !! NOTE: if one wanted to add specialized data, instead of deriving from chidgData, you could add a
        !!       chidgExtension class that could be specialized further which could contain non-standard data 
        !!  class(chidgExtension_t)

    contains
        generic, public       :: init => init_base
        procedure, private    :: init_base

    end type solverdata_t
    !-------------------------------------------------------------------------------------------------------


contains


    !>  Initialize solver base data structures
    !!      - allocate and initialize q, dq, rhs, and linearization.
    !!      - Should be called by specialized 'init' procedure for derived solvers.
    !!
    !!  @author Nathan A. Wukie
    !!  @param[in]  mesh    Mesh definition which defines storage requirements
    !----------------------------------------------------------------------------------------------------------
    subroutine init_base(self,mesh)
        class(solverdata_t),     intent(inout), target   :: self
        type(mesh_t),            intent(inout)           :: mesh(:)

        integer(ik)   :: nterms_s, ielem, nelem, neqns, ierr


        !
        ! Initialize and allocate storage
        !
        call self%q%init(  mesh)
        call self%dq%init( mesh)
        call self%rhs%init(mesh)
        call self%lhs%init(mesh,'full')

        
        !
        ! Confirm solver initialization
        !
        self%solverInitialized = .true.

    end subroutine







end module type_solverdata